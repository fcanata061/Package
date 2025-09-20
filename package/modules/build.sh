#!/usr/bin/env bash
# package/modules/build.sh
# Compila um port dentro do sandbox, executando hooks

set -euo pipefail

[ -f /etc/package.conf ] && source /etc/package.conf || true

PORTSDIR=${PORTSDIR:-/usr/ports}
WORKDIR=${WORKDIR:-/var/cache/package/work}
SANDBOX_SH=${SANDBOX_SH:-/usr/lib/package/sandbox.sh}

mkdir -p "$WORKDIR"

# Importa hooks
MODULE_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
source "$MODULE_DIR/hooks.sh"

cmd_build() {
  local category_name="$1"
  local work="$WORKDIR/${category_name//\//_}"

  mkdir -p "$work"

  # pre_build hook
  run_hook "$category_name" "pre_build"

  log_info "Compilando $category_name..."
  if [ -x "$SANDBOX_SH" ]; then
    "$SANDBOX_SH" make -C "$PORTSDIR/$category_name" build
  else
    make -C "$PORTSDIR/$category_name" build
  fi

  # post_build hook
  run_hook "$category_name" "post_build"
}

export -f cmd_build

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  [ $# -lt 1 ] && { echo "Uso: $0 <category/name>"; exit 1; }
  cmd_build "$1"
fi
