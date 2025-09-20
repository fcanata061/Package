#!/usr/bin/env bash
# modules/register.sh
# --- Registro e banco de dados de pacotes instalados ---

INSTALLED_DB=${INSTALLED_DB:-/var/lib/package/installed}
mkdir -p "$INSTALLED_DB"

: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_error:=:}"

if ! declare -F log_info >/dev/null; then log_info(){ echo "[register][INFO] $*"; }; fi
if ! declare -F log_warn >/dev/null; then log_warn(){ echo "[register][WARN] $*"; }; fi
if ! declare -F log_error >/dev/null; then log_error(){ echo "[register][ERROR] $*" >&2; }; fi

# -----------------------------------------------------------------------------
# Registrar instalação de um port
# -----------------------------------------------------------------------------
register_install() {
  local port_path="$1"   # categoria/port
  local version="$2"

  [ -n "$port_path" ] || { log_error "Uso: register_install <categoria/port> <versão>"; return 2; }
  [ -n "$version" ] || { log_error "Versão não especificada"; return 2; }

  local category="${port_path%%/*}"
  local port="${port_path##*/}"
  local key="${category}_${port}"
  local file="$INSTALLED_DB/$key"

  log_info "Registrando $port_path $version"
  {
    echo "NAME=$port"
    echo "VERSION=$version"
    echo "CATEGORY=$category"
    echo "PORT=$port"
    echo "INSTALLED_AT=$(date '+%Y-%m-%d %H:%M:%S')"
  } > "$file"

  return 0
}

# -----------------------------------------------------------------------------
# Remover registro de um port
# -----------------------------------------------------------------------------
register_remove() {
  local port_path="$1"
  local category="${port_path%%/*}"
  local port="${port_path##*/}"
  local key="${category}_${port}"
  local file="$INSTALLED_DB/$key"

  if [ -f "$file" ]; then
    rm -f "$file"
    log_info "Registro removido para $port_path"
  else
    log_warn "Nenhum registro encontrado para $port_path"
  fi
}

# -----------------------------------------------------------------------------
# Listar todos os pacotes instalados
# -----------------------------------------------------------------------------
register_list() {
  for file in "$INSTALLED_DB"/*; do
    [ -f "$file" ] || continue
    local name version
    name=$(grep "^NAME=" "$file" | cut -d= -f2)
    version=$(grep "^VERSION=" "$file" | cut -d= -f2)
    echo "$name-$version"
  done
}

# -----------------------------------------------------------------------------
# Mostrar informações de um port
# -----------------------------------------------------------------------------
register_info() {
  local port_path="$1"
  local category="${port_path%%/*}"
  local port="${port_path##*/}"
  local key="${category}_${port}"
  local file="$INSTALLED_DB/$key"

  if [ -f "$file" ]; then
    cat "$file"
  else
    log_warn "Nenhum registro encontrado para $port_path"
    return 1
  fi
}

# -----------------------------------------------------------------------------
# Verificar se está instalado
# -----------------------------------------------------------------------------
register_is_installed() {
  local port_path="$1"
  local category="${port_path%%/*}"
  local port="${port_path##*/}"
  local key="${category}_${port}"
  [ -f "$INSTALLED_DB/$key" ]
}
