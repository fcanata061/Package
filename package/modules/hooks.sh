#!/usr/bin/env bash
# modules/hooks.sh
# run_hook <port> <hook-name>
# - executa: 1) target no Makefile (se HOOKS_RUN_MAKEFILE=yes e target existir)
#            2) scripts em PORTDIR/<HOOKS_SCRIPT_DIR>/* (ordenados)
# - políticas controladas por /etc/package.conf:
#     HOOKS_RUN_MAKEFILE (yes|no)
#     HOOKS_SCRIPT_DIR (hooks)
#     HOOKS_FAIL_ON_ERROR (yes|no)  -> se yes: falha aborta; se no: continua com warning
#
# Exporta: run_hook, list_hooks

set -euo pipefail
[ -f /etc/package.conf ] && source /etc/package.conf

HOOKS_RUN_MAKEFILE=${HOOKS_RUN_MAKEFILE:-yes}
HOOKS_SCRIPT_DIR=${HOOKS_SCRIPT_DIR:-hooks}
HOOKS_FAIL_ON_ERROR=${HOOKS_FAIL_ON_ERROR:-yes}
PORTSDIR=${PORTSDIR:-/usr/ports}

# logging fallbacks
: "${log_info:=:}"; : "${log_warn:=:}"; : "${log_error:=:}"
if ! declare -F log_info >/dev/null; then log_info(){ echo "[hooks][INFO] $*"; }; fi
if ! declare -F log_warn >/dev/null; then log_warn(){ echo "[hooks][WARN] $*"; }; fi
if ! declare -F log_error >/dev/null; then log_error(){ echo "[hooks][ERROR] $*" >&2; }; fi

# verify if Makefile has a target (naive): grep '^target:'
_makefile_has_target(){
  local mf="$1" target="$2"
  [ -f "$mf" ] || return 1
  # look for "target:" at line start or ".PHONY: target" entries
  awk -v t="$target" 'BEGIN{found=0} \
    $0 ~ "^[[:space:]]*\\.PHONY" && index($0,t){found=1} \
    $0 ~ "^[[:space:]]*"t"[[:space:]]*:" {found=1} \
    END{exit !found}' "$mf"
}

# execute Makefile target if present
_run_makefile_target(){
  local port="$1" target="$2"
  local mf="$PORTSDIR/$port/Makefile"
  if [ "$HOOKS_RUN_MAKEFILE" = "yes" ] && _makefile_has_target "$mf" "$target"; then
    log_info "Executando target Makefile '$target' em $PORTSDIR/$port"
    if make -C "$PORTSDIR/$port" "$target"; then
      return 0
    else
      log_error "Target Makefile $target falhou em $port"
      return 2
    fi
  fi
  return 0
}

# execute scripts in hooks dir (ordered)
_run_hook_scripts(){
  local port="$1" hook="$2"
  local dir="$PORTSDIR/$port/$HOOKS_SCRIPT_DIR"
  [ -d "$dir" ] || return 0
  local pattern="$dir/${hook}*" f
  # iterate sorted
  for f in $(ls -1 "$dir" 2>/dev/null | grep -E "^${hook}" || true); do
    local full="$dir/$f"
    [ -x "$full" ] || { log_warn "Hook script $full não é executável, tentando com sh"; sh "$full" || { log_warn "Hook script $full falhou"; [ "$HOOKS_FAIL_ON_ERROR" = "yes" ] && return 2 || true; }; continue; }
    log_info "Executando hook script $full"
    if "$full"; then
      : # ok
    else
      log_warn "Hook script $full retornou erro"
      if [ "$HOOKS_FAIL_ON_ERROR" = "yes" ]; then
        return 2
      fi
    fi
  done
  return 0
}

# run_hook <port> <hook-name>
# order: Makefile target (if any) -> scripts in hooks dir
run_hook(){
  local port="$1" hook="$2"
  [ -n "$port" ] || { log_error "run_hook: port ausente"; return 2; }
  [ -n "$hook" ] || { log_error "run_hook: hook ausente"; return 2; }

  # 1) Makefile target (hook must be converted to Makefile-friendly target names)
  # allow both 'pre-install' and 'pre_install' naming; prefer direct
  local mf_target="${hook//-/_}"
  if ! _run_makefile_target "$port" "$mf_target"; then
    log_error "Falha no Makefile target $mf_target para $port"
    return 2
  fi

  # 2) run hook scripts in hooks dir
  if ! _run_hook_scripts "$port" "$hook"; then
    log_error "Falha ao executar scripts de hook $hook para $port"
    return 2
  fi

  return 0
}

# list_hooks <port> - prints available hooks (Makefile target + scripts)
list_hooks(){
  local port="$1"
  local mf="$PORTSDIR/$port/Makefile"
  echo "Hooks for $port:"
  if [ -f "$mf" ]; then
    echo "  Makefile targets (common): pre_install, post_install, pre_build, post_build, pre_remove, post_remove, pre_upgrade, post_upgrade"
    # naive grep for targets
    awk '/^[a-zA-Z0-9_\-]+:/ { print "   - " $1 }' "$mf" | sed 's/://'
  fi
  local dir="$PORTSDIR/$port/$HOOKS_SCRIPT_DIR"
  if [ -d "$dir" ]; then
    echo "  Hook scripts in $dir:"
    ls -1 "$dir" || true
  fi
}

# Export
export -f run_hook list_hooks

# If executed directly, provide CLI
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    run) shift; run_hook "$@";;
    list) shift; list_hooks "$@";;
    *) echo "Uso: hooks run <port> <hook>  |  hooks list <port>"; exit 2;;
  esac
fi
