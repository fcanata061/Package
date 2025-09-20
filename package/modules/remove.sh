#!/usr/bin/env bash
# package/modules/remove.sh
# Remove pacotes instalados, executando hooks

set -euo pipefail

[ -f /etc/package.conf ] && source /etc/package.conf || true

REGISTRY_DIR=${REGISTRY_DIR:-/var/lib/package/registry}
FAKEROOT_SH=${FAKEROOT_SH:-/usr/lib/package/fakeroot.sh}
SANDBOX_SH=${SANDBOX_SH:-/usr/lib/package/sandbox.sh}

# Importa hooks
MODULE_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
source "$MODULE_DIR/hooks.sh"

cmd_remove() {
  local category_name="$1"
  local portkey="${category_name//\//_}"
  local meta="$REGISTRY_DIR/${portkey}.json"
  local filelist="$REGISTRY_DIR/${portkey}.list"

  if [ ! -f "$meta" ]; then
    echo "[remove] Pacote $category_name não está instalado"
    return 0
  fi

  # pre_remove hook
  run_hook "$category_name" "pre_remove"

  echo "[remove] Removendo $category_name..."

  if [ -f "$filelist" ]; then
    while IFS= read -r f; do
      if [ -n "$f" ] && [ -e "$f" ]; then
        if [ -x "$SANDBOX_SH" ] && [ -x "$FAKEROOT_SH" ]; then
          "$SANDBOX_SH" "$FAKEROOT_SH" rm -rf "$f"
        elif [ -x "$FAKEROOT_SH" ]; then
          "$FAKEROOT_SH" rm -rf "$f"
        elif [ -x "$SANDBOX_SH" ]; then
          "$SANDBOX_SH" rm -rf "$f"
        else
          rm -rf "$f"
        fi
      fi
    done < "$filelist"
  fi

  # Limpa registro
  rm -f "$meta" "$filelist"

  # post_remove hook
  run_hook "$category_name" "post_remove"

  echo "[remove] $category_name removido com sucesso"
}

export -f cmd_remove

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  [ $# -lt 1 ] && { echo "Uso: $0 <category/name>"; exit 1; }
  cmd_remove "$1"
fi
