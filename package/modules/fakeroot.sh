#!/usr/bin/env bash
# modules/fakeroot.sh
# Simula instalação como root usando fakeroot
#
# Requer: pacote `fakeroot` instalado no sistema
#
# Variáveis de /etc/package.conf:
# FAKEROOT_DIR=/var/tmp/package-fakeroot

FAKEROOT_DIR=${FAKEROOT_DIR:-/var/tmp/package-fakeroot}

prepare_fakeroot() {
  local port_path="$1"
  mkdir -p "$FAKEROOT_DIR/$port_path"
  log "Diretório fakeroot preparado em $FAKEROOT_DIR/$port_path"
}

cleanup_fakeroot() {
  local port_path="$1"
  rm -rf "$FAKEROOT_DIR/$port_path"
  log "Diretório fakeroot limpo: $FAKEROOT_DIR/$port_path"
}

run_fakeroot() {
  local port_path="$1"
  shift
  local cmd="$*"
  prepare_fakeroot "$port_path"
  log "Executando em fakeroot: $cmd"
  fakeroot sh -c "$cmd"
}

# Comando CLI
cmd_fakeroot() {
  local action="$1"; shift || true
  case "$action" in
    prepare) prepare_fakeroot "$@" ;;
    cleanup) cleanup_fakeroot "$@" ;;
    run) run_fakeroot "$@" ;;
    *) err "Uso: package fakeroot <prepare|cleanup|run <cmd>>"; return 2 ;;
  esac
}
