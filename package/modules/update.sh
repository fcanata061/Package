#!/usr/bin/env bash
# package/modules/update.sh (revisado)
# Verifica updates de ports instalados, e opcionalmente atualiza
# Expõe: cmd_update, update_port

set -euo pipefail

[ -f /etc/package.conf ] && source /etc/package.conf || true

PORTSDIR=${PORTSDIR:-/usr/ports}
REGISTRY_DIR=${REGISTRY_DIR:-/var/lib/package/registry}
LOGFILE=${LOGFILE:-/var/log/package/update-report.txt}
USER_AGENT=${USER_AGENT:-"package-update/3.0"}
GIT_TIMEOUT=${GIT_TIMEOUT:-20}
UPDATE_DEFAULT_ACTION=${UPDATE_DEFAULT_ACTION:-"list"}   # "list" ou "auto"
UPDATE_REGEX=${UPDATE_REGEX:-""}

mkdir -p "$(dirname "$LOGFILE")" "$REGISTRY_DIR"

# Logging
: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_error:=:}"
if ! declare -F log_info >/dev/null; then log_info(){ echo "[update][INFO] $*"; }; fi
if ! declare -F log_warn >/dev/null; then log_warn(){ echo "[update][WARN] $*"; }; fi
if ! declare -F log_error >/dev/null; then log_error(){ echo "[update][ERROR] $*"; }; fi

# Load auxiliary modules/functions if exist
MODULE_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
[ -f "$MODULE_DIR/register.sh" ] && source "$MODULE_DIR/register.sh"
[ -f "$MODULE_DIR/build.sh" ] && source "$MODULE_DIR/build.sh"
[ -f "$MODULE_DIR/install.sh" ] && source "$MODULE_DIR/install.sh"
[ -f "$MODULE_DIR/remove.sh" ] && source "$MODULE_DIR/remove.sh"

# Funções de detecção
_makefile_var() {
  local mf="$1" var="$2"
  awk -v v="$var" ' $0 ~ "^[[:space:]]*"v"[[:space:]]*[:=+]" {
      line=$0
      # juntar continuação com "\"
      while(sub(/\\$/,"",line) && getline next && /\\\\$/) {line=line next}
      sub("^[[:space:]]*"v"[[:space:]]*[:=+][[:space:]]*","",line)
      gsub(/^[[:space:]]+/,"",line)
      gsub(/[[:space:]]+$/,"",line)
      print line
      exit
  }' "$mf" | sed 's/#.*//'
}

_port_version_from_makefile() {
  local mf="$1"
  local v
  for var in PORTVERSION VERSION DISTVERSION; do
    v=$(_makefile_var "$mf" "$var")
    [ -n "$v" ] && { echo "$v"; return; }
  done
  echo "0.0.0"
}

_registry_version() {
  local portkey="$1"
  local meta="${REGISTRY_DIR}/${portkey}.json"
  if [ -f "$meta" ]; then
    grep '"version"' "$meta" | sed -E 's/.*: *"([^"]+)".*/\1/' || echo "0.0.0"
  else
    echo ""
  fi
}

# Funções de comparação de versões
_compare_versions() {
  # retorna 0 se igual ou 2 se não comparável; retorna 1 se novo disponível
  [ "$1" = "$2" ] && return 0
  if printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1 | grep -qx "$1"; then
    return 1
  fi
  return 0
}

# Detecta versão mais recente do port pelo método definido no Makefile ou fallback
_detect_latest() {
  local mf="$1"
  local method regex
  method=$(_makefile_var "$mf" "UPDATE_METHOD")
  regex=$(_makefile_var "$mf" "UPDATE_REGEX")
  [ -z "$regex" ] || UPDATE_REGEX="$regex"

  case "$method" in
    git)
      local gitrepo=$(_makefile_var "$mf" "GIT_REPOSITORY")
      [ -n "$gitrepo" ] && timeout "$GIT_TIMEOUT" git ls-remote --tags "$gitrepo" 2>/dev/null | \
        awk '{print $2}' | sed 's#refs/tags/##' | grep -E "${UPDATE_REGEX:-'^[0-9]+(\\.[0-9]+)*$'}" | sort -V | tail -n1
      ;;
    svn)
      local svnrepo=$(_makefile_var "$mf" "SVN_REPOSITORY")
      [ -n "$svnrepo" ] && svn info "$svnrepo" 2>/dev/null | awk '/Revision:/ {print $2}'
      ;;
    http|ftp|https)
      # procura em MASTER_SITES por versões via regex
      local sites
      sites=$(_makefile_var "$mf" "MASTER_SITES")
      [ -n "$sites" ] && {
        local html
        if command -v curl >/dev/null; then
          html=$(curl -fsL --user-agent "$USER_AGENT" "$sites" | tr -d '\r' | tr '\n' ' ')
        elif command -v wget >/dev/null; then
          html=$(wget -qO- --user-agent "$USER_AGENT" "$sites" | tr -d '\r' | tr '\n' ' ')
        else
          return
        fi
        echo "$html" | grep -Eo "${UPDATE_REGEX:-'[0-9]+(\\.[0-9]+)*'}" | sort -V | tail -n1
      }
      ;;
    *)
      # fallback: same as http
      local sites
      sites=$(_makefile_var "$mf" "MASTER_SITES")
      if [ -n "$sites" ]; then
        local html
        if command -v curl >/dev/null; then
          html=$(curl -fsL --user-agent "$USER_AGENT" "$sites" | tr -d '\r' | tr '\n' ' ')
        elif command -v wget >/dev/null; then
          html=$(wget -qO- --user-agent "$USER_AGENT" "$sites" | tr -d '\r' | tr '\n' ' ')
        else
          return
        fi
        echo "$html" | grep -Eo "${UPDATE_REGEX:-'[0-9]+(\\.[0-9]+)*'}" | sort -V | tail -n1
      fi
      ;;
  esac
}

# Update de um único port (se necessário)
update_port() {
  local category_name="$1"
  local portkey="${category_name//\//_}"
  local port_dir="$PORTSDIR/$category_name"
  local mf="$port_dir/Makefile"
  [ -f "$mf" ] || { log_warn "Makefile não encontrado para $category_name"; return; }

  local localver installed_ver latest

  localver=$(_port_version_from_makefile "$mf")
  installed_ver=$(_registry_version "$portkey")

  if [ -z "$installed_ver" ]; then
    log_info "$category_name não está instalado; saltando"
    return
  fi

  latest=$(_detect_latest "$mf")
  if [ -z "$latest" ]; then
    log_warn "Não foi possível detectar versão mais recente para $category_name"
    return
  fi

  _compare_versions "$installed_ver" "$latest"
  if [ $? -eq 1 ]; then
    log_info "Update disponível para $category_name: $installed_ver -> $latest"
    if [ "$UPDATE_DEFAULT_ACTION" = "auto" ]; then
      log_info "Atualizando automaticamente $category_name"
      # fazer remove + build + install
      cmd_remove "${category_name//\//_}"
      cmd_build "$category_name"
      cmd_install "$category_name"
    fi
  else
    log_info "$category_name está atualizado"
  fi
}

cmd_update() {
  log_info "=== Iniciando update geral em $(date) ==="
  echo "==== Relatório de Updates $(date) ====" > "$LOGFILE"
  # iterar pacotes registrados
  for meta in "$REGISTRY_DIR"/*.json; do
    [ -f "$meta" ] || continue
    local portkey version
    portkey=$(basename "$meta" .json)
    version=$(grep '"version"' "$meta" | sed -E 's/.*: *"([^"]+)".*/\1/')
    # converter portkey de volta para category/name
    # se portkey foi “category_name”:
    local category_name="${portkey//_//}"  # depende de seu padrão
    update_port "$category_name"
  done
  log_info "Update geral completo"
}

export -f update_port cmd_update

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  # uso direto
  if [ $# -lt 1 ]; then
    echo "Uso: $0 <category/name> | all" >&2
    exit 1
  fi
  if [ "$1" = "all" ]; then
    cmd_update
  else
    update_port "$1"
  fi
fi
