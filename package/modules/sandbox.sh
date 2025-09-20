#!/usr/bin/env bash
# sandbox.sh - módulo de execução em sandbox
# Fornece funções para executar comandos em isolamento
# Integra com build.sh, hooks.sh, fakeroot.sh e demais módulos

set -euo pipefail
IFS=$'\n\t'

MODULE_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
LOG_DIR=${LOG_DIR:-/var/log/package}
SANDBOX_METHOD=${SANDBOX_METHOD:-none}  # none, chroot, bwrap, fakeroot
SANDBOX_ROOT=${SANDBOX_ROOT:-/tmp/package-sandbox}

mkdir -p "$LOG_DIR"

# Logging mínimo (usa logs.sh se disponível)
if ! declare -F log_info >/dev/null 2>&1; then
  log_info(){ echo "[sandbox][INFO] $*"; }
fi
if ! declare -F log_warn >/dev/null 2>&1; then
  log_warn(){ echo "[sandbox][WARN] $*"; }
fi
if ! declare -F log_error >/dev/null 2>&1; then
  log_error(){ echo "[sandbox][ERROR] $*" >&2; }
fi

# Cria o sandbox se necessário
sandbox_init(){
  case "$SANDBOX_METHOD" in
    none)
      log_info "Sandbox: desabilitado (execução direta)"
      ;;
    fakeroot)
      command -v fakeroot >/dev/null || { log_error "fakeroot não instalado"; return 1; }
      log_info "Sandbox: usando fakeroot"
      ;;
    bwrap)
      command -v bwrap >/dev/null || { log_error "bubblewrap (bwrap) não instalado"; return 1; }
      mkdir -p "$SANDBOX_ROOT"
      log_info "Sandbox: usando bubblewrap em $SANDBOX_ROOT"
      ;;
    chroot)
      [ -d "$SANDBOX_ROOT" ] || { log_error "Sandbox root não encontrado: $SANDBOX_ROOT"; return 1; }
      command -v chroot >/dev/null || { log_error "chroot não disponível"; return 1; }
      log_info "Sandbox: usando chroot em $SANDBOX_ROOT"
      ;;
    *)
      log_error "Método de sandbox desconhecido: $SANDBOX_METHOD"; return 1
      ;;
  esac
}

# Executa comando dentro do sandbox
sandbox_exec(){
  local logfile="$LOG_DIR/sandbox-$(date +%s).log"
  case "$SANDBOX_METHOD" in
    none)
      log_info "Execução direta: $*"
      "$@" | tee -a "$logfile"
      ;;
    fakeroot)
      log_info "Execução em fakeroot: $*"
      fakeroot -- "$@" | tee -a "$logfile"
      ;;
    bwrap)
      log_info "Execução em bubblewrap: $*"
      bwrap --unshare-net --unshare-pid --dev-bind / / \
        --bind "$SANDBOX_ROOT" /buildroot \
        --chdir /buildroot \
        bash -lc "$*" | tee -a "$logfile"
      ;;
    chroot)
      log_info "Execução em chroot: $*"
      chroot "$SANDBOX_ROOT" /bin/bash -lc "$*" | tee -a "$logfile"
      ;;
    *)
      log_error "sandbox_exec: método inválido: $SANDBOX_METHOD"; return 1
      ;;
  esac
}

# Limpa o sandbox
sandbox_cleanup(){
  case "$SANDBOX_METHOD" in
    bwrap)
      log_info "Limpando sandbox bwrap em $SANDBOX_ROOT"
      rm -rf "$SANDBOX_ROOT"/* || true
      ;;
    chroot)
      log_info "Chroot em $SANDBOX_ROOT, não removendo rootfs automaticamente"
      ;;
    fakeroot|none)
      :
      ;;
  esac
}

export -f sandbox_init
export -f sandbox_exec
export -f sandbox_cleanup
