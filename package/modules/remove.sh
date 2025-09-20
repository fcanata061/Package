#!/usr/bin/env bash
# modules/remove.sh
# Remoção de pacotes baseados em lista de arquivos gerada por install.sh
# Usa register.sh para checar/atualizar registro, e hooks pre/post-remove.
#
# Exporta: cmd_remove <categoria/port> [--dry-run] [--skip-hooks]
# Remove serviços systemd se SERVICE_ENABLE=yes e pacote definir SERVICE_UNIT (Makefile)
# Respeita FILES_DIR e FILES_LIST_NAME via /etc/package.conf

set -euo pipefail

[ -f /etc/package.conf ] && source /etc/package.conf

FILES_DIR=${FILES_DIR:-/var/lib/package/files}
FILES_LIST_NAME=${FILES_LIST_NAME:-package.files}
INSTALLED_DB_DIR=${INSTALLED_DB_DIR:-${INSTALLED_DB:-/var/lib/package/installed}}

mkdir -p "$FILES_DIR" "$INSTALLED_DB_DIR"

# logging fallbacks
: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_error:=:}"
: "${log_port:=:}"
if ! declare -F log_info >/dev/null; then log_info(){ echo "[remove][INFO] $*"; }; fi
if ! declare -F log_warn >/dev/null; then log_warn(){ echo "[remove][WARN] $*"; }; fi
if ! declare -F log_error >/dev/null; then log_error(){ echo "[remove][ERROR] $*" >&2; }; fi
if ! declare -F log_port >/dev/null; then log_port(){ echo "[$1] $2"; }; fi

# external hooks/register functions expected (with fallbacks)
: "${run_hook:=:}"
if ! declare -F run_hook >/dev/null; then run_hook(){ log_warn "run_hook não implementado: $*"; return 0; }; fi
: "${register_is_installed:=:}"
if ! declare -F register_is_installed >/dev/null; then
  register_is_installed(){ local p="$1"; [ -f "${INSTALLED_DB_DIR}/$(echo "$p" | tr '/' '_').json" ]; }
fi
: "${register_remove:=:}"
if ! declare -F register_remove >/dev/null; then
  register_remove(){ log_warn "register_remove não implementado: $*"; return 0; }
fi

_run_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    if command -v sudo >/dev/null 2>&1; then
      sudo "$@"
    else
      log_error "Operação precisa de root (ou sudo): $*"
      return 1
    fi
  fi
}

_files_list_path() {
  local port="$1"
  local name=$(echo "$port" | tr '/' '_')
  printf '%s/%s.list' "$FILES_DIR" "$name"
}

# stop systemd service if defined in Makefile (SERVICE_UNIT or name)
_stop_service_if_defined() {
  local port="$1" mf="$PORTSDIR/$port/Makefile"
  [ -f "$mf" ] || return 0
  local unit
  unit=$(awk -F= '/^SERVICE_UNIT[[:space:]]*=/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$mf" | tr -d '"')
  if [ -z "$unit" ]; then
    # try default: service name = last component of port
    unit=$(basename "$port")
  fi
  if [ "${SYSTEMD:-yes}" != "yes" ]; then
    log_info "Systemd integration desabilitada; não paro serviços para $port"
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1; then
    log_info "Parando e desabilitando unit $unit (se existir)"
    _run_as_root systemctl stop "$unit" || true
    _run_as_root systemctl disable "$unit" || true
    _run_as_root systemctl daemon-reload || true
  fi
  return 0
}

# remove files listed in listfile; supports dry-run
_remove_files_from_list() {
  local listfile="$1" dry="${2:-0}" port="$3"
  [ -f "$listfile" ] || { log_warn "Lista de arquivos não encontrada: $listfile"; return 0; }

  local failcount=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    # safety: avoid removing root or empty
    if [ "$f" = "/" ] || [ -z "$f" ] || [[ "$f" =~ ^\.\.?$ ]]; then
      log_warn "Ignorando caminho inseguro: $f"
      continue
    fi
    if [ "$dry" -eq 1 ]; then
      log_info "[dry-run] remover $f"
    else
      if [ -e "$f" ]; then
        # try to remove file, fallback to sudo if necessary
        if rm -f "$f" 2>/dev/null; then
          log_port "$port" "Removido: $f"
        else
          log_warn "Falha ao remover $f sem sudo, tentando sudo"
          if _run_as_root rm -f "$f"; then
            log_port "$port" "Removido (sudo): $f"
          else
            log_error "Falha ao remover $f (necessita intervenção manual)"
            failcount=$((failcount+1))
          fi
        fi
      else
        # maybe it's a directory
        if [ -d "$f" ]; then
          if rmdir "$f" 2>/dev/null; then
            log_port "$port" "Diretório removido: $f"
          else
            # try recursive remove (careful)
            log_warn "Tentando remoção recursiva de diretório: $f"
            if rm -rf "$f" 2>/dev/null; then
              log_port "$port" "Diretório removido recursivamente: $f"
            else
              if _run_as_root rm -rf "$f"; then
                log_port "$port" "Diretório removido recursivamente (sudo): $f"
              else
                log_error "Falha ao remover diretório $f"
                failcount=$((failcount+1))
              fi
            fi
          fi
        else
          log_warn "Arquivo não existe: $f"
        fi
      fi
    fi
  done < "$listfile"

  return $failcount
}

cmd_remove() {
  local port="$1"; shift || true
  local dry=0 skip_hooks=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1; shift ;;
      --skip-hooks) skip_hooks=1; shift ;;
      *) shift ;;
    esac
  done

  [ -n "$port" ] || { log_error "Uso: package remove <categoria/port> [--dry-run]"; return 2; }

  # sanity: check registration
  if ! register_is_installed "$port"; then
    log_warn "Pacote $port não registrado como instalado; ainda assim tentarei remover arquivos se lista existir"
  fi

  # run pre-remove hooks
  if [ "$skip_hooks" -ne 1 ]; then
    run_hook "$port" "pre-remove" || { log_warn "pre-remove hook retornou não-zero (continuando)"; }
  fi

  # stop service if exists
  _stop_service_if_defined "$port"

  # remove files
  local listfile; listfile=$(_files_list_path "$port")
  if [ -f "$listfile" ]; then
    log_info "Removendo arquivos listados em $listfile"
    if ! _remove_files_from_list "$listfile" "$dry" "$port"; then
      log_warn "Alguns arquivos falharam ao remover. Verifique logs."
    fi
    if [ "$dry" -eq 0 ]; then
      # remove the files list itself
      rm -f "$listfile" || log_warn "Não foi possível remover lista $listfile"
    fi
  else
    log_warn "Lista de arquivos não encontrada ($listfile). Nada a remover a partir dela."
  fi

  # run post-remove hooks
  if [ "$skip_hooks" -ne 1 ]; then
    run_hook "$port" "post-remove" || { log_warn "post-remove hook retornou não-zero"; }
  fi

  # unregister package
  if [ "$dry" -eq 0 ]; then
    register_remove "$port"
  else
    log_info "[dry-run] não removendo registro para $port"
  fi

  log_info "Remoção de $port concluída (dry=$dry)"
  return 0
}

export -f cmd_remove
