#!/usr/bin/env bash
# package/modules/upgrade.sh
# Atualiza pacotes instalados, com suporte a hooks

set -euo pipefail

[ -f /etc/package.conf ] && source /etc/package.conf || true

PORTSDIR=${PORTSDIR:-/usr/ports}
REGISTRY_DIR=${REGISTRY_DIR:-/var/lib/package/registry}

# Importa módulos
MODULE_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
source "$MODULE_DIR/hooks.sh"
source "$MODULE_DIR/build.sh"
source "$MODULE_DIR/install.sh"
source "$MODULE_DIR/remove.sh"
source "$MODULE_DIR/register.sh"

# Helpers
get_installed_version() {
  local category_name="$1"
  local portkey="${category_name//\//_}"
  local meta="$REGISTRY_DIR/${portkey}.json"
  [ -f "$meta" ] && grep '"version"' "$meta" | sed -E 's/.*: *"([^"]+)".*/\1/' || echo ""
}

_get_makefile_var() {
  local mf="$1" var="$2"
  awk -v v="$var" '
    $0 ~ "^[[:space:]]*"v"[[:space:]]*[:=+]" {
      line=$0
      while (sub(/\\$/,"",line) && getline next) { line=line next }
      sub("^[[:space:]]*"v"[[:space:]]*[:=+][[:space:]]*","",line)
      gsub(/^[[:space:]]+/,"",line)
      gsub(/[[:space:]]+$/,"",line)
      print line
      exit
  }' "$mf" | sed 's/#.*//' | xargs
}

get_port_version() {
  local category_name="$1"
  local mf="$PORTSDIR/$category_name/Makefile"
  for var in PORTVERSION VERSION DISTVERSION; do
    local v=$(_get_makefile_var "$mf" "$var")
    [ -n "$v" ] && { echo "$v"; return; }
  done
  echo "0.0.0"
}

version_newer() {
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" != "$1" ]
}

upgrade_port() {
  local category_name="$1"

  local installed_ver
  installed_ver=$(get_installed_version "$category_name")
  [ -z "$installed_ver" ] && { echo "[upgrade] $category_name não está instalado"; return 0; }

  local new_ver
  new_ver=$(get_port_version "$category_name")

  if version_newer "$installed_ver" "$new_ver"; then
    echo "[upgrade] $category_name: $installed_ver → $new_ver"

    # pre_upgrade hook
    run_hook "$category_name" "pre_upgrade"

    # remove + build + install
    cmd_remove "$category_name"
    cmd_build "$category_name"
    cmd_install "$category_name"

    # registra nova versão
    register_port "${category_name//\//_}" "$new_ver" "$REGISTRY_DIR/${category_name//\//_}.list"

    # post_upgrade hook
    run_hook "$category_name" "post_upgrade"

    echo "[upgrade] $category_name atualizado para $new_ver"
  else
    echo "[upgrade] $category_name já está na última versão ($installed_ver)"
  fi
}

cmd_upgrade() {
  if [ "$1" = "--all" ]; then
    for meta in "$REGISTRY_DIR"/*.json; do
      [ -f "$meta" ] || continue
      local portkey=$(basename "$meta" .json)
      local category_name="${portkey//_//}"
      upgrade_port "$category_name"
    done
  else
    for cn in "$@"; do
      upgrade_port "$cn"
    done
  fi
}

export -f cmd_upgrade upgrade_port

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  [ $# -lt 1 ] && { echo "Uso: $0 <category/name> | --all"; exit 1; }
  cmd_upgrade "$@"
fi
