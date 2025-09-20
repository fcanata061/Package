#!/usr/bin/env bash
# modules/sync.sh
# Sincroniza a árvore de ports (/usr/ports) com um repositório remoto
#
# Requer: git instalado
#
# Variáveis em /etc/package.conf:
# PORTS_REPO=https://github.com/usuario/ports.git
# PORTSDIR=/usr/ports

PORTS_REPO=${PORTS_REPO:-""}

cmd_sync() {
  [ -n "$PORTS_REPO" ] || { err "PORTS_REPO não definido em /etc/package.conf"; return 2; }

  if [ ! -d "$PORTSDIR/.git" ]; then
    log "Clonando repositório de ports em $PORTSDIR"
    rm -rf "$PORTSDIR"
    git clone "$PORTS_REPO" "$PORTSDIR"
  else
    log "Atualizando árvore de ports em $PORTSDIR"
    git -C "$PORTSDIR" pull --rebase
  fi
}
