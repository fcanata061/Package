#!/usr/bin/env bash
# modules/sandbox.sh
# Fornece execução em sandbox para builds/installs de ports
#
# Suporta:
# - chroot simples
# - systemd-nspawn (se disponível)
#
# Requer um diretório base para sandbox definido em /etc/package.conf:
# SANDBOX_DIR=/var/sandbox/package

SANDBOX_DIR=${SANDBOX_DIR:-/var/sandbox/package}

prepare_sandbox() {
  local port_path="$1"
  mkdir -p "$SANDBOX_DIR"

  # Criar estrutura mínima
  for d in bin lib lib64 usr var tmp etc; do
    mkdir -p "$SANDBOX_DIR/$d"
  done

  # Montar bind mounts necessários
  mount --bind /dev "$SANDBOX_DIR/dev"
  mount --bind /proc "$SANDBOX_DIR/proc"
  mount --bind /sys "$SANDBOX_DIR/sys"
  log "Sandbox preparada em $SANDBOX_DIR para $port_path"
}

cleanup_sandbox() {
  umount -lf "$SANDBOX_DIR/dev" 2>/dev/null || true
  umount -lf "$SANDBOX_DIR/proc" 2>/dev/null || true
  umount -lf "$SANDBOX_DIR/sys" 2>/dev/null || true
  log "Sandbox desmontada em $SANDBOX_DIR"
}

run_in_sandbox() {
  local cmd="$*"
  if command -v systemd-nspawn >/dev/null 2>&1; then
    log "Executando em sandbox (systemd-nspawn): $cmd"
    systemd-nspawn -D "$SANDBOX_DIR" /bin/bash -c "$cmd"
  else
    log "Executando em sandbox (chroot): $cmd"
    chroot "$SANDBOX_DIR" /bin/bash -c "$cmd"
  fi
}

# Comando CLI
cmd_sandbox() {
  local action="$1"; shift || true
  case "$action" in
    prepare) prepare_sandbox "$@" ;;
    cleanup) cleanup_sandbox ;;
    run) run_in_sandbox "$@" ;;
    *) err "Uso: package sandbox <prepare|cleanup|run <cmd>>"; return 2 ;;
  esac
}
