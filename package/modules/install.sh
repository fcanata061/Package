#!/usr/bin/env bash
# modules/install.sh
# Responsável por instalar artefatos compilados

cmd_install() {
  local port_path="$1"
  [ -n "$port_path" ] || { err "install requer port (ex: net/httpd)"; return 2; }
  log "Instalando $port_path no PREFIX=$PREFIX"
  # Este esqueleto supõe que o Makefile do port fornece 'install' target
  local portdir="$PORTSDIR/$port_path"
  make -C "$portdir" PREFIX="$PREFIX" install
}
