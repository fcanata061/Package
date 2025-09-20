#!/usr/bin/env bash
# package/modules/register.sh (revisado)
# Módulo “register” para o gerenciador “package”
# - Registro de pacotes instalados
# - Expor: cmd_register_list, cmd_register_info, register_port

set -euo pipefail

[ -f /etc/package.conf ] && source /etc/package.conf || true

PORTSDIR=${PORTSDIR:-/usr/ports}
FILES_DIR=${FILES_DIR:-/var/lib/package/files}
REGISTRY_DIR=${REGISTRY_DIR:-/var/lib/package/registry}
LOG_DIR=${LOG_DIR:-/var/log/package}

mkdir -p "$FILES_DIR" "$REGISTRY_DIR" "$LOG_DIR"

# Logging
: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_error:=:}"

if ! declare -F log_info >/dev/null; then
  log_info(){ echo "[register][INFO] $*"; }
fi
if ! declare -F log_warn >/dev/null; then
  log_warn(){ echo "[register][WARN] $*"; }
fi
if ! declare -F log_error >/dev/null; then
  log_error(){ echo "[register][ERROR] $*"; }
fi

# Helper: port key derivado do caminho do port
_port_key_from_rel() {
  local rel="$1"
  # remove prefix PORTSDIR/ se presente
  rel="${rel#$PORTSDIR/}"
  # substitui / por _
  printf '%s' "${rel//\//_}"
}

# Registrar um port: salvar metadados e lista de arquivos
register_port() {
  local portkey="$1"
  local portver="$2"
  local files_list="$3"

  [ -f "$files_list" ] || { log_error "register_port: lista de arquivos não encontrada: $files_list"; return 1; }

  # registro de metadata
  local meta_file="${REGISTRY_DIR}/${portkey}.json"
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # montar JSON simples
  cat > "$meta_file" <<EOF
{
  "portkey": "${portkey}",
  "version": "${portver}",
  "installed_at": "${now}",
  "files_list": "${files_list}"
}
EOF

  log_info "Pacote registrado: ${portkey} v${portver} -> ${meta_file}"
}

# Listar pacotes registrados
cmd_register_list() {
  # lista nomes de chaves no REGISTRY_DIR
  for f in "$REGISTRY_DIR"/*.json; do
    [ -f "$f" ] || continue
    basename "$f" .json
  done
}

# Mostrar informações de um pacote registrado
cmd_register_info() {
  local portkey="$1"
  [ -n "$portkey" ] || { log_error "Uso: package register info <portkey>"; return 2; }
  local meta_file="${REGISTRY_DIR}/${portkey}.json"
  if [ ! -f "$meta_file" ]; then
    log_error "Não há registro para '${portkey}'"
    return 1
  fi
  cat "$meta_file"
}

export -f register_port cmd_register_list cmd_register_info

# Integração CLI
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  # Se chamado como script direto
  case "$1" in
    list)
      shift
      cmd_register_list
      ;;
    info)
      shift
      cmd_register_info "$1"
      ;;
    *)
      echo "Uso: $0 list | info <portkey>" >&2
      exit 1
      ;;
  esac
fi
