#!/usr/bin/env bash
# modules/register.sh
#
# Registro de pacotes no banco local (/var/lib/package/db).
# Cada pacote tem um manifest.json + registro global (INSTALLED_INDEX.json).
#
# Comandos:
#   register_package <name> <version> <staging_dir>
#   unregister_package <name> <version>
#   list_packages
#   info_package <name>

set -euo pipefail

[ -f /etc/package.conf ] && source /etc/package.conf

DBDIR=${DBDIR:-/var/lib/package/db}
INDEX="$DBDIR/INSTALLED_INDEX.json"
mkdir -p "$DBDIR"

# --- Logging ---
: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_error:=:}"

if ! declare -F log_info >/dev/null; then
  log_info(){ echo "[register][INFO] $*"; }
fi
if ! declare -F log_warn >/dev/null; then
  log_warn(){ echo "[register][WARN] $*"; }
fi
if ! declare -F log_error >/dev/null; then
  log_error(){ echo "[register][ERROR] $*" >&2; }
fi

# --- Dependências internas ---
MODULESDIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
source "$MODULESDIR/logs.sh"

# --- Funções auxiliares ---
_init_index() {
  [ -f "$INDEX" ] || echo "[]" > "$INDEX"
}

_manifest_file() {
  local name="$1" version="$2"
  echo "$DBDIR/$name-$version.manifest.json"
}

# --- Registrar pacote ---
register_package() {
  local name="$1" version="$2" staging="$3"

  _init_index

  local manifest="$(_manifest_file "$name" "$version")"
  log_info "Registrando $name-$version em $manifest"

  {
    echo "{"
    echo "  \"name\": \"$name\","
    echo "  \"version\": \"$version\","
    echo "  \"date\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"files\": ["
    find "$staging" -type f | sed "s#^$staging#$PREFIX#" | sed 's/$/,/' | sed '$ s/,$//'
    echo "  ]"
    echo "}"
  } > "$manifest"

  # Atualizar índice global
  tmp=$(mktemp)
  jq --arg n "$name" --arg v "$version" \
     '. += [{"name":$n,"version":$v}]' "$INDEX" > "$tmp" && mv "$tmp" "$INDEX"

  log_event "register" "$name" "$version" "success"
}

# --- Remover registro ---
unregister_package() {
  local name="$1" version="$2"

  _init_index

  local manifest="$(_manifest_file "$name" "$version")"
  rm -f "$manifest"

  tmp=$(mktemp)
  jq --arg n "$name" --arg v "$version" \
     'map(select(.name != $n or .version != $v))' "$INDEX" > "$tmp" && mv "$tmp" "$INDEX"

  log_info "Registro de $name-$version removido do banco"
  log_event "unregister" "$name" "$version" "success"
}

# --- Listar pacotes ---
list_packages() {
  _init_index
  jq -r '.[] | "\(.name)-\(.version)"' "$INDEX"
}

# --- Mostrar info ---
info_package() {
  local name="$1"
  _init_index

  jq --arg n "$name" '.[] | select(.name==$n)' "$INDEX"
}

# --- Export ---
export -f register_package unregister_package list_packages info_package

# Execução direta
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    register)
      shift
      if [ $# -lt 3 ]; then
        echo "Uso: $0 register <name> <version> <staging_dir>"
        exit 1
      fi
      register_package "$@"
      ;;
    unregister)
      shift
      if [ $# -lt 2 ]; then
        echo "Uso: $0 unregister <name> <version>"
        exit 1
      fi
      unregister_package "$@"
      ;;
    list)
      list_packages
      ;;
    info)
      shift
      if [ $# -lt 1 ]; then
        echo "Uso: $0 info <name>"
        exit 1
      fi
      info_package "$1"
      ;;
    *)
      echo "Uso: $0 {register|unregister|list|info}"
      exit 1
      ;;
  esac
fi
