#!/usr/bin/env bash
# modules/dependency.sh
# Responsável por resolver dependências de um port

cmd_deps() {
  local port_path="$1"
  [ -n "$port_path" ] || { err "deps requer port (ex: net/httpd)"; return 2; }
  local portdir="$PORTSDIR/$port_path"
  [ -d "$portdir" ] || { err "Port não encontrado: $portdir"; return 3; }

  log "Resolvendo dependências para $port_path"

  # Lê a variável DEPENDS do Makefile do port
  local deps
  deps=$(sed -n 's/^DEPENDS[[:space:]]*=\\s*\\(.*\\)/\\1/p' "$portdir/Makefile" || true)

  if [ -n "$deps" ]; then
    for d in $deps; do
      log "-> Instalando dependência: $d"
      cmd_fetch "$d"
      cmd_build "$d"
      cmd_install "$d"
    done
  else
    log "Nenhuma dependência declarada para $port_path"
  fi
}
