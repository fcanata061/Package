#!/usr/bin/env bash
# modules/register.sh (atualizado)
# - gerencia metadados JSON por pacote
# - mantém índice (INSTALLED_INDEX) e faz rotação/backups de JSONs
# - fornece cmd_register_list / cmd_register_info
# - faz backup de JSONs ao atualizar/remover

set -euo pipefail
[ -f /etc/package.conf ] && source /etc/package.conf

INSTALLED_DB_DIR=${INSTALLED_DB_DIR:-${INSTALLED_DB:-/var/lib/package/installed}}
INSTALLED_INDEX=${INSTALLED_INDEX:-"${INSTALLED_DB_DIR}/index.txt"}
FILES_DIR=${FILES_DIR:-/var/lib/package/files}

# rotation/backup settings
LOG_ROTATE_DAYS=${LOG_ROTATE_DAYS:-30}   # usado por logs; também pode aplicar aqui
INSTALLED_INDEX_RETENTION_DAYS=${INSTALLED_INDEX_RETENTION_DAYS:-90}
INSTALLED_JSON_BACKUP=${INSTALLED_JSON_BACKUP:-yes}
INSTALLED_JSON_BACKUP_DIR=${INSTALLED_JSON_BACKUP_DIR:-"${INSTALLED_DB_DIR}/backups"}

mkdir -p "$INSTALLED_DB_DIR" "$FILES_DIR" "$INSTALLED_JSON_BACKUP_DIR"

# logging fallbacks
: "${log_info:=:}"; : "${log_warn:=:}"; : "${log_error:=:}"
if ! declare -F log_info >/dev/null; then log_info(){ echo "[register][INFO] $*"; }; fi
if ! declare -F log_warn >/dev/null; then log_warn(){ echo "[register][WARN] $*"; }; fi
if ! declare -F log_error >/dev/null; then log_error(){ echo "[register][ERROR] $*" >&2; }; fi

_json_escape(){ printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

_register_meta_path(){ local port="$1"; printf '%s/%s.json' "$INSTALLED_DB_DIR" "$(echo "$port" | tr '/' '_')"; }
_register_files_list_path(){ local port="$1"; printf '%s/%s.list' "$FILES_DIR" "$(echo "$port" | tr '/' '_')"; }

_index_add_or_update(){
  local port="$1" version="$2" ts
  ts=$(date +%s)
  mkdir -p "$(dirname "$INSTALLED_INDEX")"
  if [ -f "$INSTALLED_INDEX" ]; then
    grep -vF -- "$port " "$INSTALLED_INDEX" > "${INSTALLED_INDEX}.tmp" || true
    mv -f "${INSTALLED_INDEX}.tmp" "$INSTALLED_INDEX"
  fi
  printf '%s %s %s\n' "$port" "$version" "$ts" >> "$INSTALLED_INDEX"
}

_index_remove(){
  local port="$1"
  [ -f "$INSTALLED_INDEX" ] || return 0
  grep -vF -- "$port " "$INSTALLED_INDEX" > "${INSTALLED_INDEX}.tmp" || true
  mv -f "${INSTALLED_INDEX}.tmp" "$INSTALLED_INDEX"
}

# Backup JSON before overwrite/remove
_backup_meta_json(){
  local meta="$1"
  [ -f "$meta" ] || return 0
  if [ "${INSTALLED_JSON_BACKUP:-yes}" != "yes" ]; then return 0; fi
  local date_dir
  date_dir=$(date '+%Y%m%d')
  mkdir -p "${INSTALLED_JSON_BACKUP_DIR}/${date_dir}"
  cp -a "$meta" "${INSTALLED_JSON_BACKUP_DIR}/${date_dir}/" || log_warn "Falha ao copiar $meta para backups"
}

register_install(){
  local port="$1" version="${2:-unknown}"
  [ -n "$port" ] || { log_error "register_install: port ausente"; return 2; }
  local meta=$(_register_meta_path "$port")
  local files_list=$(_register_files_list_path "$port")
  local ts human
  ts=$(date +%s)
  human=$(date -d @"$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')
  mkdir -p "$(dirname "$meta")"

  # backup existing meta
  _backup_meta_json "$meta"

  {
    printf '{\n'
    printf '  "port": "%s",\n' "$(_json_escape "$port")"
    printf '  "version": "%s",\n' "$(_json_escape "$version")"
    printf '  "installed_at": "%s",\n' "$(_json_escape "$human")"
    printf '  "installed_ts": %s,\n' "$ts"
    if [ -f "$files_list" ]; then
      printf '  "files": [\n'
      local first=1
      while IFS= read -r file || [ -n "$file" ]; do
        [ -z "$file" ] && continue
        if [ $first -eq 1 ]; then printf '    "%s"\n' "$(_json_escape "$file")"; first=0
        else printf '    ,"%s"\n' "$(_json_escape "$file")"; fi
      done < "$files_list"
      printf '  ]\n'
    else
      printf '  "files": []\n'
    fi
    printf '}\n'
  } > "${meta}.tmp" && mv -f "${meta}.tmp" "$meta"

  _index_add_or_update "$port" "$version"
  log_info "register_install: $port v$version registrado"
}

register_remove(){
  local port="$1"
  [ -n "$port" ] || { log_error "register_remove: port ausente"; return 2; }
  local meta=$(_register_meta_path "$port")
  # backup meta before removal
  _backup_meta_json "$meta"
  if [ -f "$meta" ]; then rm -f "$meta" || log_warn "Não foi possível remover $meta"; fi
  _index_remove "$port"
  log_info "register_remove: $port removido do índice"
}

register_is_installed(){
  local port="$1"; [ -n "$port" ] || return 1
  [ -f "$(_register_meta_path "$port")" ]
}

get_installed_version(){
  local port="$1"; [ -n "$port" ] || return 1
  local meta=$(_register_meta_path "$port")
  if [ -f "$meta" ]; then
    awk -F: '/"version"[[:space:]]*:/ { gsub(/[",]/,"",$2); gsub(/^[[:space:]]+/,"",$2); print $2; exit }' "$meta"
  else
    printf ''
  fi
}

cmd_register_list(){
  if [ ! -f "$INSTALLED_INDEX" ]; then log_info "Índice vazio"; return 0; fi
  awk '{ printf "%-40s %10s %s\n", $1, $2, strftime("%Y-%m-%d %H:%M:%S", $3) }' "$INSTALLED_INDEX"
}

cmd_register_info(){
  local port="$1"; [ -n "$port" ] || { log_error "Uso: package register info <cat/port>"; return 2; }
  local meta=$(_register_meta_path "$port")
  if [ -f "$meta" ]; then cat "$meta"; else log_error "Meta não encontrada para $port"; return 1; fi
}

# rotation/cleanup of old index entries & old backups
_register_maintenance(){
  # remove index entries older than INSTALLED_INDEX_RETENTION_DAYS by deleting entries with TS older
  if [ -f "$INSTALLED_INDEX" ] && [ "${INSTALLED_INDEX_RETENTION_DAYS:-0}" -gt 0 ]; then
    local cutoff
    cutoff=$(date -d "-${INSTALLED_INDEX_RETENTION_DAYS} days" +%s 2>/dev/null || echo "")
    if [ -n "$cutoff" ]; then
      awk -v c="$cutoff" '$3 >= c { print $0 }' "$INSTALLED_INDEX" > "${INSTALLED_INDEX}.tmp" && mv -f "${INSTALLED_INDEX}.tmp" "$INSTALLED_INDEX"
      log_info "register: index rotacionado (retenção ${INSTALLED_INDEX_RETENTION_DAYS} dias)"
    fi
  fi
  # optionally prune backups older than retention (use LOG_ROTATE_DAYS or a dedicated var)
  if [ -n "${LOG_ROTATE_DAYS:-}" ] && [ "${LOG_ROTATE_DAYS}" -gt 0 ]; then
    if command -v find >/dev/null 2>&1; then
      find "$INSTALLED_JSON_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +$LOG_ROTATE_DAYS -exec rm -rf {} + 2>/dev/null || true
      log_info "register: backups antigos limpos (> $LOG_ROTATE_DAYS dias)"
    fi
  fi
}

# run maintenance in background at load time
_register_maintenance &>/dev/null &

export -f register_install register_remove register_is_installed get_installed_version cmd_register_list cmd_register_info

# CLI convenience
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    list) shift; cmd_register_list "$@";;
    info) shift; cmd_register_info "$@";;
    install) shift; register_install "$@";;
    remove) shift; register_remove "$@";;
    *) echo "Usage: register (list|info|install|remove)"; exit 2;;
  esac
fi
