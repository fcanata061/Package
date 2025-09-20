#!/usr/bin/env bash
# modules/remove.sh
#
# Remove pacotes instalados.
# Usa manifest.json para saber os arquivos e move tudo para a lixeira
# em vez de deletar diretamente.
#
# Fluxo:
#   1. Localiza manifest JSON no DBDIR
#   2. Executa hooks pre-remove
#   3. Move arquivos para trashdir
#   4. Desativa serviços (systemd)
#   5. Executa hooks post-remove
#   6. Remove do banco de pacotes

set -euo pipefail

[ -f /etc/package.conf ] && source /etc/package.conf

DBDIR=${DBDIR:-/var/lib/package/db}
LOGDIR=${LOGDIR:-/var/log/package}
TRASHDIR=${TRASHDIR:-/var/lib/package/trash}
mkdir -p "$DBDIR" "$LOGDIR" "$TRASHDIR"

# --- Logging ---
: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_error:=:}"

if ! declare -F log_info >/dev/null; then
  log_info(){ echo "[remove][INFO] $*"; }
fi
if ! declare -F log_warn >/dev/null; then
  log_warn(){ echo "[remove][WARN] $*"; }
fi
if ! declare -F log_error >/dev/null; then
  log_error(){ echo "[remove][ERROR] $*" >&2; }
fi

# --- Dependências internas ---
MODULESDIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
source "$MODULESDIR/hooks.sh"
source "$MODULESDIR/logs.sh"
source "$MODULESDIR/service.sh"

# --- Função principal ---
remove_package() {
  local name="$1" version="${2:-}"

  # Localizar manifest
  local manifest
  if [ -n "$version" ]; then
    manifest="$DBDIR/$name-$version.manifest.json"
  else
    manifest=$(ls "$DBDIR"/"$name"-*.manifest.json 2>/dev/null | sort -V | tail -n1 || true)
  fi

  [ -f "$manifest" ] || {
    log_error "Manifest não encontrado para $name"
    return 1
  }

  version=$(jq -r .version "$manifest")
  log_info "=== Removendo $name-$version ==="
  log_event "remove" "$name" "$version" "start"

  # Hooks pre-remove
  run_hook pre-remove "$name"

  # Criar diretório de lixeira
  local trash="$TRASHDIR/${name}-${version}-$(date +%s)"
  mkdir -p "$trash"

  # Desativar serviços
  if [ -d "/etc/systemd/system" ]; then
    log_info "Desativando serviços do $name"
    systemctl disable "$name"*.service 2>/dev/null || true
    systemctl stop "$name"*.service 2>/dev/null || true
  fi

  # Mover arquivos para trash
  jq -r '.files[]' "$manifest" | while read -r f; do
    if [ -f "$f" ] || [ -d "$f" ]; then
      local dest="$trash$f"
      mkdir -p "$(dirname "$dest")"
      mv "$f" "$dest" || log_warn "Falha ao mover $f"
    fi
  done

  # Hooks post-remove
  run_hook post-remove "$name"

  # Remover manifest e registro do banco
  rm -f "$manifest"
  log_info "Registro de $name-$version removido"

  log_event "remove" "$name" "$version" "success"
  log_info "Remoção concluída. Arquivos movidos para $trash"
}

export -f remove_package

# Execução direta
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ $# -lt 1 ]; then
    echo "Uso: $0 <nome> [versão]"
    exit 1
  fi
  remove_package "$@"
fi
