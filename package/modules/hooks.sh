#!/usr/bin/env bash
# modules/hooks.sh
# --- Hooks integrados ao Makefile de cada port ---
#
# Em vez de scripts separados, os hooks são alvos do próprio Makefile:
#   pre-configure
#   post-configure
#   pre-build
#   post-build
#   pre-install
#   post-install
#   pre-remove
#   post-remove
#
# Chamados pelo build.sh em cada fase.

PORTSDIR=${PORTSDIR:-/usr/ports}
HOOK_LOG_DIR=${HOOK_LOG_DIR:-/var/log/package/hooks}
mkdir -p "$HOOK_LOG_DIR"

: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_error:=:}"

if ! declare -F log_info >/dev/null; then log_info(){ echo "[hooks][INFO] $*"; }; fi
if ! declare -F log_warn >/dev/null; then log_warn(){ echo "[hooks][WARN] $*"; }; fi
if ! declare -F log_error >/dev/null; then log_error(){ echo "[hooks][ERROR] $*" >&2; }; fi

# -----------------------------------------------------------------------------
# Executar hook definido no Makefile
# -----------------------------------------------------------------------------
hooks_run() {
  local port_path="$1"
  local phase="$2"
  local workdir="$3"

  local makefile="$PORTSDIR/$port_path/Makefile"
  local logfile="$HOOK_LOG_DIR/$(echo "$port_path" | tr '/' '_')_${phase}.log"

  [ -f "$makefile" ] || { log_warn "Nenhum Makefile em $port_path"; return 0; }

  # Checar se alvo existe no Makefile
  if grep -q "^${phase}:" "$makefile"; then
    log_info "Executando hook '$phase' via Makefile em $port_path"
    ( cd "$workdir" && make -f "$makefile" "$phase" DESTDIR="$workdir/stage" ) >>"$logfile" 2>&1
    if [ $? -ne 0 ]; then
      log_error "Hook $phase falhou em $port_path — veja $logfile"
      return 1
    fi
  else
    log_info "Hook $phase não definido em $port_path"
  fi
}
