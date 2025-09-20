#!/usr/bin/env bash
# package/modules/upgrade.sh (revisado)
# Gerenciamento de upgrades de ports
# Expõe: cmd_upgrade, upgrade_port

set -euo pipefail

[ -f /etc/package.conf ] && source /etc/package.conf || true

PORTSDIR=${PORTSDIR:-/usr/ports}
REGISTRY_DIR=${REGISTRY_DIR:-/var/lib/package/registry}
LOG_DIR=${LOG_DIR:-/var/log/package}
PARALLEL_JOBS=${PARALLEL_JOBS:-1}
UPDATE_DEFAULT_ACTION=${UPDATE_DEFAULT_ACTION:-"check"}  # "check" ou "upgrade"

mkdir -p "$REGISTRY_DIR" "$LOG_DIR"

# Logging
: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_error:=:}"
: "${log_event:=:}"

if ! declare -F log_info >/dev/null; then log_info(){ echo "[upgrade][INFO] $*"; }; fi
if ! declare -F log_warn >/dev/null; then log_warn(){ echo "[upgrade][WARN] $*"; }; fi
if ! declare -F log_error >/dev/null; then log_error(){ echo "[upgrade][ERROR] $*" >&2; }; fi
if ! declare -F log_event >/dev/null; then log_event(){ :; }; fi

# Carrega módulos auxiliares
MODULE_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
[ -f "$MODULE_DIR/register.sh" ] && source "$MODULE_DIR/register.sh"
[ -f "$MODULE_DIR/build.sh" ] && source "$MODULE_DIR/build.sh"
[ -f "$MODULE_DIR/install.sh" ] && source "$MODULE_DIR/install.sh"
[ -f "$MODULE_DIR/remove.sh" ] && source "$MODULE_DIR/remove.sh"
[ -f "$MODULE_DIR/hooks.sh" ] && source "$MODULE_DIR/hooks.sh"

# Funções auxiliares baseadas no register module

is_installed() {
  local category_name="$1"
  local portkey="${category_name//\//_}"
  local meta="${REGISTRY_DIR}/${portkey}.json"
  [ -f "$meta" ]
}

get_installed_version() {
  local category_name="$1"
  local portkey="${category_name//\//_}"
  local meta="${REGISTRY_DIR}/${portkey}.json"
  if [ -f "$meta" ]; then
    grep '"version"' "$meta" | sed -E 's/.*: *"([^"]+)".*/\1/' || echo ""
  else
    echo ""
  fi
}

# Extrai versão do Makefile
_makefile_var() {
  local mf="$1" var="$2"
  awk -v v="$var" ' $0 ~ "^[[:space:]]*"v"[[:space:]]*[:=+]" {
      line=$0
      while(sub(/\\$/,"",line) && getline next && /\\\\$/) { line=line next }
      sub("^[[:space:]]*"v"[[:space:]]*[:=+][[:space:]]*","",line)
      gsub(/^[[:space:]]+/,"",line)
      gsub(/[[:space:]]+$/,"",line)
      print line
      exit
  }' "$mf" | sed 's/#.*//'
}

_port_new_version() {
  local category_name="$1"
  local mf="$PORTSDIR/$category_name/Makefile"
  if [ ! -f "$mf" ]; then
    log_warn "Makefile não encontrado para $category_name"
    echo ""
    return 1
  fi
  local ver
  for var in PORTVERSION VERSION DISTVERSION; do
    ver=$(_makefile_var "$mf" "$var")
    [ -n "$ver" ] && { echo "$ver"; return 0; }
  done
  echo "0.0.0"
}

_compare_versions() {
  # retorna 0 se igual ou novo ≤ instalado; retorna 1 se novo > instalado
  local v1="$1" v2="$2"
  if [ "$v1" = "$v2" ]; then
    return 0
  fi
  if printf '%s\n%s\n' "$v1" "$v2" | sort -V | head -n1 | grep -qx "$v1"; then
    # v1 < v2
    return 1
  else
    return 0
  fi
}

upgrade_port() {
  local category_name="$1"
  local force=0
  # assumir force=0; pode modificar se quiser

  if ! is_installed "$category_name"; then
    log_warn "$category_name não está instalado — pulando"
    return 0
  fi

  local installed_ver
  installed_ver=$(get_installed_version "$category_name")
  local new_ver
  new_ver=$(_port_new_version "$category_name") || return 1

  if [ -z "$new_ver" ]; then
    log_warn "Não achei nova versão para $category_name"
    return 0
  fi

  _compare_versions "$installed_ver" "$new_ver"
  if [ $? -eq 1 ] || [ "$force" = "1" ]; then
    log_info "Upgrade detectado: $category_name $installed_ver → $new_ver"
    log_event "upgrade" "$category_name" "$installed_ver" "start"
    # hook
    run_hook "$category_name" "pre_upgrade"

    # remover versão antiga
    cmd_remove "$category_name"

    # build + install nova
    cmd_build "$category_name"
    cmd_install "$category_name"

    # registrar
    register_port "${category_name//\//_}" "$new_ver" "$FILES_DIR/${category_name//\//_}.list"

    run_hook "$category_name" "post_upgrade"
    log_info "Upgrade concluído para $category_name v$new_ver"
    log_event "upgrade" "$category_name" "$installed_ver" "success"
  else
    log_info "$category_name já está na versão mais recente ($installed_ver)"
  fi
}

cmd_upgrade() {
  local force=0
  local all=0
  local ports=()

  for arg in "$@"; do
    case "$arg" in
      --force) force=1 ;;
      --all) all=1 ;;
      *) ports+=("$arg") ;;
    esac
  done

  if [ "$all" = "1" ]; then
    # todos os pacotes instalados
    # listar do registro
    for meta in "$REGISTRY_DIR"/*.json; do
      [ -f "$meta" ] || continue
      local portkey version
      portkey=$(basename "$meta" .json)
      # converter portkey -> category/name
      local category_name="${portkey//_//}"
      ports+=("$category_name")
    done
  fi

  if [ ${#ports[@]} -eq 0 ]; then
    log_error "Uso: package upgrade <category/name> | --all [--force]"
    return 2
  fi

  for cn in "${ports[@]}"; do
    upgrade_port "$cn"
  done
}

export -f cmd_upgrade upgrade_port

# Se for executado diretamente
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ $# -lt 1 ]; then
    echo "Uso: $0 <category/name> | --all [--force]" >&2
    exit 1
  fi
  cmd_upgrade "$@"
fi
