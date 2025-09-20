#!/usr/bin/env bash
# modules/upgrade.sh
# --- Gerenciamento de upgrades de ports ---

PORTSDIR=${PORTSDIR:-/usr/ports}
INSTALLED_DB=${INSTALLED_DB:-/var/lib/package/installed}
PARALLEL_JOBS=${PARALLEL_JOBS:-1}

: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_error:=:}"
: "${log_port:=:}"
: "${register_install:=:}"
: "${is_installed:=:}"
: "${get_installed_version:=:}"
: "${cmd_build:=:}"
: "${cmd_remove:=:}"
: "${cmd_deps:=:}"
: "${run_hook:=:}"
: "${register_action:=:}"

if ! declare -F log_info >/dev/null; then log_info(){ echo "[upgrade][INFO] $*"; }; fi
if ! declare -F log_warn >/dev/null; then log_warn(){ echo "[upgrade][WARN] $*"; }; fi
if ! declare -F log_error >/dev/null; then log_error(){ echo "[upgrade][ERROR] $*" >&2; }; fi
if ! declare -F log_port >/dev/null; then log_port(){ echo "[$1] $2"; }; fi

# -------------------------------------------------------------------
# Lê versão nova do Makefile
# -------------------------------------------------------------------
_get_new_version() {
  local port_path="$1"
  local makefile="$PORTSDIR/$port_path/Makefile"
  [ -f "$makefile" ] || { log_error "Makefile não encontrado para $port_path"; return 1; }
  local ver
  ver=$(grep -E '^(VERSION|PORTVERSION)[[:space:]]*=' "$makefile" | head -n1 | awk -F= '{print $2}' | tr -d ' "')
  [ -n "$ver" ] || ver="unknown"
  echo "$ver"
}

# -------------------------------------------------------------------
# Upgrade de um único port
# -------------------------------------------------------------------
_upgrade_one() {
  local port_path="$1" force="$2" check_only="$3"

  if ! is_installed "$port_path"; then
    log_warn "Pacote $port_path não está instalado, ignorando"
    return 0
  fi

  local ver_inst ver_new
  ver_inst=$(get_installed_version "$port_path" || echo "")
  ver_new=$(_get_new_version "$port_path") || return 1

  if [ "$check_only" = "1" ]; then
    if [ "$ver_inst" != "$ver_new" ] || [ "$force" = "1" ]; then
      echo "$port_path (instalado=$ver_inst, disponível=$ver_new)"
    fi
    return 0
  fi

  if [ "$ver_inst" = "$ver_new" ] && [ "$force" != "1" ]; then
    log_info "[$port_path] já atualizado ($ver_inst)"
    return 0
  fi

  log_info "[$port_path] Upgrade $ver_inst → $ver_new"
  log_port "$port_path" "Iniciando upgrade $ver_inst → $ver_new"

  # hook pre_upgrade
  run_hook "$port_path" "pre_upgrade" || return 1

  # dependências
  cmd_deps "$port_path" || return 1

  # backup versão antiga
  local backup_pkg="$port_path@$ver_inst"

  # remover versão antiga
  cmd_remove "$port_path" || return 1

  # instalar nova
  if ! cmd_build "$port_path"; then
    log_error "Falha no build de $port_path, restaurando versão anterior"
    cmd_build "$backup_pkg" 2>/dev/null || log_warn "Não foi possível restaurar $backup_pkg"
    return 1
  fi

  # hook post_upgrade
  run_hook "$port_path" "post_upgrade"

  # registrar
  register_install "$port_path" "$ver_new"
  register_action "upgrade" "$port_path" "success"

  log_info "[$port_path] Upgrade concluído ($ver_new)"
}

# -------------------------------------------------------------------
# Comando principal
# -------------------------------------------------------------------
cmd_upgrade() {
  local force=0 check_only=0 all=0
  local ports=()

  for arg in "$@"; do
    case "$arg" in
      --force) force=1 ;;
      --check-only) check_only=1 ;;
      --all) all=1 ;;
      *) ports+=("$arg") ;;
    esac
  done

  if [ "$all" = "1" ]; then
    # pegar todos instalados
    mapfile -t ports < <(awk '{print $1}' "$INSTALLED_DB" 2>/dev/null)
  fi

  [ ${#ports[@]} -gt 0 ] || { log_error "Uso: package upgrade <port...> [--force] [--check-only] [--all]"; return 2; }

  # hook pre_upgrade_all
  run_hook "global" "pre_upgrade_all"

  if [ "$PARALLEL_JOBS" -gt 1 ] && [ "$check_only" != "1" ]; then
    printf '%s\n' "${ports[@]}" | xargs -n1 -P"$PARALLEL_JOBS" bash -c '_upgrade_one "$@"' _ -- "$force" "$check_only"
  else
    for port in "${ports[@]}"; do
      _upgrade_one "$port" "$force" "$check_only"
    done
  fi

  # hook post_upgrade_all
  run_hook "global" "post_upgrade_all"
}
