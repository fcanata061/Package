#!/usr/bin/env bash
# modules/register.sh
# Registro de pacotes instalados (metadados JSON) e utilitários.
#
# Exporta:
#   register_install <categoria/port> <version>
#   register_remove  <categoria/port>
#   register_is_installed <categoria/port> (retorna 0 se instalado)
#   get_installed_version <categoria/port> (imprime versão ou vazio)
#   cmd_register_list
#   cmd_register_info <categoria/port>
#
# Metadados JSON por pacote: INSTALLED_DB_DIR/<categoria_port>.json
# Também mantém um índice texto INSTALLED_DB (uma linha por pacote: "<port> <version> <timestamp>")

set -euo pipefail

# load config if present
[ -f /etc/package.conf ] && source /etc/package.conf

INSTALLED_DB_DIR=${INSTALLED_DB_DIR:-${INSTALLED_DB:-/var/lib/package/installed}}
INSTALLED_INDEX=${INSTALLED_INDEX:-"${INSTALLED_DB_DIR}/index.txt"}
FILES_DIR=${FILES_DIR:-/var/lib/package/files}
mkdir -p "$INSTALLED_DB_DIR" "$FILES_DIR"

# logging fallbacks
: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_error:=:}"
if ! declare -F log_info >/dev/null; then log_info(){ echo "[register][INFO] $*"; }; fi
if ! declare -F log_warn >/dev/null; then log_warn(){ echo "[register][WARN] $*"; }; fi
if ! declare -F log_error >/dev/null; then log_error(){ echo "[register][ERROR] $*" >&2; }; fi

_json_escape() {
  # simples escape para strings JSON (não robusto para binários, mas suficiente)
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r/\\r/g' -e 's/\n/\\n/g'
}

# normalized path for metadata file
_register_meta_path() {
  local port="$1"
  local name=$(echo "$port" | tr '/' '_')
  printf '%s/%s.json' "$INSTALLED_DB_DIR" "$name"
}

# update central index: one line per package: "<port> <version> <timestamp>"
_index_add_or_update() {
  local port="$1" version="$2" ts
  ts=$(date +%s)
  mkdir -p "$(dirname "$INSTALLED_INDEX")"
  # remove existing
  if [ -f "$INSTALLED_INDEX" ]; then
    grep -vF -- "$port " "$INSTALLED_INDEX" > "${INSTALLED_INDEX}.tmp" || true
    mv -f "${INSTALLED_INDEX}.tmp" "$INSTALLED_INDEX"
  fi
  printf '%s %s %s\n' "$port" "$version" "$ts" >> "$INSTALLED_INDEX"
}

_index_remove() {
  local port="$1"
  [ -f "$INSTALLED_INDEX" ] || return 0
  grep -vF -- "$port " "$INSTALLED_INDEX" > "${INSTALLED_INDEX}.tmp" || true
  mv -f "${INSTALLED_INDEX}.tmp" "$INSTALLED_INDEX"
}

# read files list path
_register_files_list_path() {
  local port="$1"
  local base="${FILES_DIR:-/var/lib/package/files}"
  local name=$(echo "$port" | tr '/' '_')
  printf '%s/%s.list' "$base" "$name"
}

# register_install <port> <version>
register_install() {
  local port="$1" version="${2:-unknown}"
  [ -n "$port" ] || { log_error "register_install: port ausente"; return 2; }
  local meta_file; meta_file=$(_register_meta_path "$port")
  local files_list; files_list=$(_register_files_list_path "$port")
  local ts human

  ts=$(date +%s)
  human=$(date -d @"$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')

  mkdir -p "$(dirname "$meta_file")"

  # build JSON
  {
    printf '{\n'
    printf '  "port": "%s",\n' "$(_json_escape "$port")"
    printf '  "version": "%s",\n' "$(_json_escape "$version")"
    printf '  "installed_at": "%s",\n' "$(_json_escape "$human")"
    printf '  "installed_ts": %s,\n' "$ts"
    if [ -f "$files_list" ]; then
      printf '  "files": [\n'
      local first=1
      while IFS= read -r file; do
        [ -z "$file" ] && continue
        if [ $first -eq 1 ]; then
          printf '    "%s"\n' "$(_json_escape "$file")"
          first=0
        else
          printf '    ,"%s"\n' "$(_json_escape "$file")"
        fi
      done < "$files_list"
      printf '  ]\n'
    else
      printf '  "files": []\n'
    fi
    printf '}\n'
  } > "${meta_file}.tmp" && mv -f "${meta_file}.tmp" "$meta_file"

  # update index
  _index_add_or_update "$port" "$version"

  log_info "register_install: $port v$version registrado em $meta_file"
  return 0
}

# register_remove <port>
register_remove() {
  local port="$1"
  [ -n "$port" ] || { log_error "register_remove: port ausente"; return 2; }
  local meta_file; meta_file=$(_register_meta_path "$port")
  local files_list; files_list=$(_register_files_list_path "$port")

  if [ -f "$meta_file" ]; then
    rm -f "$meta_file" || log_warn "Não foi possível remover meta $meta_file"
  else
    log_warn "register_remove: metadado não encontrado para $port"
  fi

  # remove index entry
  _index_remove "$port"

  # optionally remove files list? keep by default for audit; remove if config requests
  if [ "${REMOVE_FILES_LIST_ON_UNREGISTER:-no}" = "yes" ]; then
    [ -f "$files_list" ] && rm -f "$files_list"
  fi

  log_info "register_remove: $port removido do registro"
  return 0
}

# register_is_installed <port> -> return 0 if installed
register_is_installed() {
  local port="$1"
  [ -n "$port" ] || return 1
  local meta_file; meta_file=$(_register_meta_path "$port")
  [ -f "$meta_file" ]
}

# get_installed_version <port> -> prints version or empty
get_installed_version() {
  local port="$1"
  [ -n "$port" ] || return 1
  local meta_file; meta_file=$(_register_meta_path "$port")
  if [ -f "$meta_file" ]; then
    # crude parse: find "version": "..."
    awk -F: '/"version"[[:space:]]*:/ { gsub(/[",]/,"",$2); gsub(/^[[:space:]]+/,"",$2); print $2; exit }' "$meta_file"
  else
    printf ''
  fi
}

# CLI helpers
cmd_register_list() {
  if [ ! -f "$INSTALLED_INDEX" ]; then
    log_info "Nenhum pacote registrado (index vazio)"
    return 0
  fi
  awk '{ printf "%-40s %10s %s\n", $1, $2, strftime("%Y-%m-%d %H:%M:%S", $3) }' "$INSTALLED_INDEX"
}

cmd_register_info() {
  local port="$1"
  [ -n "$port" ] || { log_error "Uso: package register-info <categoria/port>"; return 2; }
  local meta_file; meta_file=$(_register_meta_path "$port")
  if [ -f "$meta_file" ]; then
    cat "$meta_file"
  else
    log_error "Nenhum metadado encontrado para $port"
    return 1
  fi
}

# Export functions
export -f register_install register_remove register_is_installed get_installed_version cmd_register_list cmd_register_info

# If module invoked as script, offer CLI
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    list) shift; cmd_register_list "$@"; exit $? ;;
    info) shift; cmd_register_info "$@"; exit $? ;;
    install) shift; register_install "$@"; exit $? ;;
    remove) shift; register_remove "$@"; exit $? ;;
    *) echo "Uso: register (list|info|install|remove)"; exit 2 ;;
  esac
fi
