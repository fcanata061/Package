#!/usr/bin/env bash
# modules/remove.sh
# Remove pacotes movendo arquivos para TRASH_DIR (recuperável) em vez de apagar imediatamente.
# cmd_remove <categoria/port> [--dry-run] [--skip-hooks]
# Lê /etc/package.conf para FILES_DIR, TRASH_DIR, FILES_LIST_NAME, SYSTEMD, etc.

set -euo pipefail
[ -f /etc/package.conf ] && source /etc/package.conf

FILES_DIR=${FILES_DIR:-/var/lib/package/files}
FILES_LIST_NAME=${FILES_LIST_NAME:-package.files}
INSTALLED_DB_DIR=${INSTALLED_DB_DIR:-${INSTALLED_DB:-/var/lib/package/installed}}
TRASH_DIR=${TRASH_DIR:-/var/lib/package/trash}
TRASH_KEEP_DAYS=${TRASH_KEEP_DAYS:-30}   # opcional: limpeza automática antiga

mkdir -p "$FILES_DIR" "$INSTALLED_DB_DIR" "$TRASH_DIR"

# logging fallbacks
: "${log_info:=:}"; : "${log_warn:=:}"; : "${log_error:=:}"; : "${log_port:=:}"
if ! declare -F log_info >/dev/null; then log_info(){ echo "[remove][INFO] $*"; }; fi
if ! declare -F log_warn >/dev/null; then log_warn(){ echo "[remove][WARN] $*"; }; fi
if ! declare -F log_error >/dev/null; then log_error(){ echo "[remove][ERROR] $*" >&2; }; fi
if ! declare -F log_port >/dev/null; then log_port(){ echo "[$1] $2"; }; fi

: "${run_hook:=:}"
if ! declare -F run_hook >/dev/null; then run_hook(){ log_warn "run_hook não disponível: $*"; return 0; }; fi
: "${register_remove:=:}"
if ! declare -F register_remove >/dev/null; then register_remove(){ log_warn "register_remove não implementado: $*"; return 0; }; fi
: "${register_is_installed:=:}"
if ! declare -F register_is_installed >/dev/null; then
  register_is_installed(){ local p="$1"; [ -f "${INSTALLED_DB_DIR}/$(echo "$p" | tr '/' '_').json" ]; }
fi

_run_as_root(){
  if [ "$(id -u)" -eq 0 ]; then "$@"; else
    if command -v sudo >/dev/null 2>&1; then sudo "$@"; else log_error "Operação precisa de root: $*"; return 1; fi
  fi
}

_files_list_path(){
  local port="$1"
  printf '%s/%s.list' "$FILES_DIR" "$(echo "$port" | tr '/' '_')"
}

# ensure destination in TRASH_DIR, preserve structure and timestamp
_move_to_trash(){
  local src="$1" port="$2"
  [ -e "$src" ] || { log_warn "Arquivo não existe ao mover para lixeira: $src"; return 0; }
  local rel
  # build relative path (strip leading /)
  rel="${src#/}"
  # target path under TRASH_DIR/<port>/<rel>
  local target_dir="${TRASH_DIR}/$(echo "$port" | tr '/' '_')/$(dirname "$rel")"
  mkdir -p "$target_dir"
  # move with sudo if needed
  if mv "$src" "$target_dir/" 2>/dev/null; then
    log_port "$port" "Movido para lixeira: $src -> $target_dir/"
  else
    if _run_as_root mv "$src" "$target_dir/"; then
      log_port "$port" "Movido para lixeira (sudo): $src -> $target_dir/"
    else
      log_error "Falha ao mover $src para lixeira"
      return 1
    fi
  fi
  return 0
}

# remove (move) files listed in listfile (dry-run supported)
_remove_files_from_list(){
  local listfile="$1" dry="$2" port="$3"
  [ -f "$listfile" ] || { log_warn "Lista de arquivos não encontrada: $listfile"; return 0; }
  local failcount=0
  while IFS= read -r f || [ -n "$f" ]; do
    [ -z "$f" ] && continue
    # safety checks
    if [ "$f" = "/" ] || [ -z "$f" ]; then log_warn "Ignorando caminho inseguro: $f"; continue; fi
    if [ "$dry" -eq 1 ]; then
      log_info "[dry-run] mover $f -> $TRASH_DIR/$(echo "$port" | tr '/' '_')/"
      continue
    fi
    if ! _move_to_trash "$f" "$port"; then failcount=$((failcount+1)); fi
  done < "$listfile"
  return $failcount
}

# optionally cleanup old trash files older than TRASH_KEEP_DAYS
_trash_maintenance(){
  local days="${TRASH_KEEP_DAYS:-0}"
  if [ -n "$days" ] && [ "$days" -gt 0 ]; then
    if command -v find >/dev/null 2>&1; then
      log_info "Limpando lixeira: removendo itens com mais de $days dias"
      _run_as_root find "$TRASH_DIR" -mindepth 2 -mtime +"$days" -exec rm -rf {} + 2>/dev/null || true
    fi
  fi
}

_stop_service_if_defined(){
  local port="$1" mf="$PORTSDIR/$port/Makefile"
  [ -f "$mf" ] || return 0
  local unit
  unit=$(awk -F= '/^SERVICE_UNIT[[:space:]]*=/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$mf" | tr -d '"')
  [ -z "$unit" ] && unit=$(basename "$port")
  if [ "${SYSTEMD:-yes}" != "yes" ]; then log_info "Systemd integration desabilitada"; return 0; fi
  if command -v systemctl >/dev/null 2>&1; then
    log_info "Parando e desabilitando unit $unit (se existir)"
    _run_as_root systemctl stop "$unit" || true
    _run_as_root systemctl disable "$unit" || true
    _run_as_root systemctl daemon-reload || true
  fi
}

cmd_remove(){
  local port="$1"; shift || true
  local dry=0 skip_hooks=0
  while [ $# -gt 0 ]; do
    case "$1" in --dry-run) dry=1; shift ;; --skip-hooks) skip_hooks=1; shift ;; *) shift ;; esac
  done

  [ -n "$port" ] || { log_error "Uso: package remove <categoria/port> [--dry-run]"; return 2; }

  if ! register_is_installed "$port"; then
    log_warn "Pacote $port não registrado como instalado; ainda assim tentarei remover arquivos se lista existir"
  fi

  if [ "$skip_hooks" -ne 1 ]; then
    run_hook "$port" "pre-remove" || log_warn "pre-remove hook falhou (continuando)"
  fi

  _stop_service_if_defined "$port"

  local listfile; listfile=$(_files_list_path "$port")
  if [ -f "$listfile" ]; then
    log_info "Movendo arquivos listados em $listfile para lixeira"
    if ! _remove_files_from_list "$listfile" "$dry" "$port"; then
      log_warn "Alguns arquivos falharam ao mover para lixeira; verifique logs"
    fi
    if [ "$dry" -eq 0 ]; then
      # move listfile to trash as well (for audit) or remove depending on config
      if [ "${REMOVE_FILES_LIST_ON_UNREGISTER:-no}" = "yes" ]; then
        rm -f "$listfile" || log_warn "Não foi possível remover lista $listfile"
      else
        # move to trash folder for this port
        _move_to_trash "$listfile" "$port" || true
      fi
    fi
  else
    log_warn "Lista de arquivos não encontrada ($listfile)"
  fi

  if [ "$skip_hooks" -ne 1 ]; then
    run_hook "$port" "post-remove" || log_warn "post-remove hook falhou"
  fi

  if [ "$dry" -eq 0 ]; then
    register_remove "$port"
  else
    log_info "[dry-run] registro não alterado para $port"
  fi

  # background: maintain trash (cleanup old)
  _trash_maintenance &

  log_info "Remoção (move-to-trash) de $port concluída (dry=$dry)"
  return 0
}

export -f cmd_remove
