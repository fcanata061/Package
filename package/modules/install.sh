#!/usr/bin/env bash
# package/modules/install.sh
# Instala um port usando fakeroot e sandbox, executando hooks

set -euo pipefail

[ -f /etc/package.conf ] && source /etc/package.conf || true

PORTSDIR=${PORTSDIR:-/usr/ports}
FAKEROOT_SH=${FAKEROOT_SH:-/usr/lib/package/fakeroot.sh}
SANDBOX_SH=${SANDBOX_SH:-/usr/lib/package/sandbox.sh}

# Importa hooks
MODULE_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
source "$MODULE_DIR/hooks.sh"

cmd_install() {
  local category_name="$1"

  # pre_install hook
  run_hook "$category_name" "pre_install"

  log_info "Instalando $category_name..."
  if [ -x "$SANDBOX_SH" ]; then
    if [ -x "$FAKEROOT_SH" ]; then
      "$SANDBOX_SH" "$FAKEROOT_SH" make -C "$PORTSDIR/$category_name" install
    else
      "$SANDBOX_SH" make -C "$PORTSDIR/$category_name" install
    fi
  else
    if [ -x "$FAKEROOT_SH" ]; then
      "$FAKEROOT_SH" make -C "$PORTSDIR/$category_name" install
    else
      make -C "$PORTSDIR/$category_name" install
    fi
  fi

  # post_install hook
  run_hook "$category_name" "post_install"
}

export -f cmd_install

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  [ $# -lt 1 ] && { echo "Uso: $0 <category/name>"; exit 1; }
  cmd_install "$1"
fi
