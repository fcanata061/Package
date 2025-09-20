#!/usr/bin/env bash
# package/modules/remove.sh (revisado)
# Módulo “remove” para o gerenciador “package”
# - Remove arquivos instalados de um pacote dado seu portkey ou category/name
# - Usa registro (register.sh) para saber quais arquivos remover
# - Usa fakeroot/sandbox quando disponível
# - Atualiza base de registro removendo o pacote
# - Expõe: cmd_remove, remove_port

set -euo pipefail

[ -f /etc/package.conf ] && source /etc/package.conf || true

PORTSDIR=${PORTSDIR:-/usr/ports}
FILES_DIR=${FILES_DIR:-/var/lib/package/files}
REGISTRY_DIR=${REGISTRY_DIR:-/var/lib/package/registry}
LOG_DIR=${LOG_DIR:-/var/log/package}
PREFIX=${PREFIX:-/usr/local}

mkdir -p "$FILES_DIR" "$REGISTRY_DIR" "$LOG_DIR"

# Logging
: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_error:=:}"
: "${log_event:=:}"

if ! declare -F log_info >/dev/null; then log_info(){ echo "[remove][INFO] $*"; }; fi
if ! declare -F log_warn >/dev/null; then log_warn(){ echo "[remove][WARN] $*"; }; fi
if ! declare -F log_error >/dev/null; then log_error(){ echo "[remove][ERROR] $*"; }; fi
if ! declare -F log_event >/dev/null; then log_event(){ :; }; fi

# Carrega módulos auxiliares
MODULE_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
[ -f "$MODULE_DIR/register.sh" ] && source "$MODULE_DIR/register.sh"
[ -f "$MODULE_DIR/fakeroot.sh" ] && source "$MODULE_DIR/fakeroot.sh"
[ -f "$MODULE_DIR/sandbox.sh" ] && source "$MODULE_DIR/sandbox.sh"

# Fallbacks se funções não existirem
if ! declare -F sandbox_exec >/null 2>&1; then
  sandbox_exec(){ bash -c "$*"; }
fi

# Função para remover usando fakeroot dentro de sandbox quando possível
_remove_files_list() {
  local listfile="$1"
  if [ ! -f "$listfile" ]; then
    log_error "Arquivo de lista de arquivos para remoção não encontrado: $listfile"
    return 1
  fi

  while IFS= read -r f; do
    # f começa com “/…” conforme lista de arquivos
    local abs="$PREFIX${f#/}"  # ou se lista já for absoluta, ajustar
    if [ -e "$abs" ]; then
      log_info "Removendo: $abs"
      rm -f "$abs" || log_warn "Falha ao remover $abs"
    else
      log_warn "Arquivo não existe (pulando): $abs"
    fi
  done < "$listfile"
  return 0
}

remove_port() {
  local portkey="$1"

  [ -n "$portkey" ] || { log_error "Uso: remove_port <portkey>"; return 2; }

  local meta_file="${REGISTRY_DIR}/${portkey}.json"
  if [ ! -f "$meta_file" ]; then
    log_error "Pacote não registrado: $portkey"
    return 1
  fi

  # extrai version e files_list do meta
  local portver files_list
  portver=$(grep '"version"' "$meta_file" | sed -E 's/.*: *"([^"]+)".*/\1/') || portver="unknown"
  files_list=$(grep '"files_list"' "$meta_file" | sed -E 's/.*: *"([^"]+)".*/\1/') || { log_error "Não achei files_list no registro"; return 1; }

  log_info "=== Iniciando remoção: $portkey v$portver ==="
  log_event "remove" "$portkey" "$portver" "start"

  # uso de sandbox/fakeroot para remover
  if declare -F fakeroot >/dev/null 2>&1; then
    log_info "Usando fakeroot para remoção"
    if [ "${SANDBOX_METHOD:-none}" != "none" ]; then
      log_info "Dentro de sandbox ($SANDBOX_METHOD)"
      sandbox_exec "fakeroot _remove_files_list '$files_list'"
    else
      fakeroot _remove_files_list "$files_list"
    fi
  else
    log_warn "fakeroot não disponível; removendo diretamente (pode exigir privilégios)"
    _remove_files_list "$files_list"
  fi

  # Remover registro JSON
  rm -f "$meta_file" || log_warn "Falha ao remover meta_file $meta_file"

  # Também remover arquivo de lista (se quiser)
  if [ -f "$files_list" ]; then
    rm -f "$files_list" || log_warn "Falha ao remover lista de arquivos $files_list"
  fi

  log_info "Remoção concluída para $portkey"
  log_event "remove" "$portkey" "$portver" "success"

  return 0
}

cmd_remove() {
  local port="$1"
  [ -n "$port" ] || { log_error "Uso: package remove <portkey>"; return 2; }
  # se usar category/name em vez de portkey, pode converter
  local portkey="${port//\//_}"
  remove_port "$portkey"
}

export -f cmd_remove remove_port

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ $# -lt 1 ]; then
    echo "Uso: $0 <portkey> | <category/name>" >&2
    exit 1
  fi
  cmd_remove "$1"
fi
