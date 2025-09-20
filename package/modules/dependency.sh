#!/usr/bin/env bash
# modules/dependency.sh
# Gerenciamento avançado de dependências
#
# Suporta:
#   BUILD_DEPENDS= categoria/port>=versao
#   RUN_DEPENDS=   categoria/port
#   TEST_DEPENDS=  categoria/port
#
# Salva lockfile em /usr/ports/<port>/DEPENDENCIES.lock
# Mantém cache em /var/lib/package/deps/<port>.dep

PORTSDIR=${PORTSDIR:-/usr/ports}
INSTALLED_DB=${INSTALLED_DB:-/var/lib/package/installed}
DEPS_CACHE=${DEPS_CACHE:-/var/lib/package/deps}
mkdir -p "$DEPS_CACHE"

is_installed() {
  local port_path="$1"
  grep -q "^$port_path " "$INSTALLED_DB"
}

get_installed_version() {
  local port_path="$1"
  grep "^$port_path " "$INSTALLED_DB" | awk '{print $2}'
}

# Extrai dependências de um tipo do Makefile
get_depends() {
  local port_path="$1"
  local type="$2" # BUILD_DEPENDS, RUN_DEPENDS, TEST_DEPENDS
  local makefile="$PORTSDIR/$port_path/Makefile"
  [ -f "$makefile" ] || return 0
  grep "^${type}" "$makefile" | sed "s/^${type}=//;s/\\//g" | tr -d '\n' | tr ' ' '\n'
}

version_ge() {
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

# Resolve dependências de um tipo
resolve_type() {
  local port_path="$1"
  local type="$2"
  local seen="$3"
  local stack="$4"

  local deps
  deps=$(get_depends "$port_path" "$type")

  for dep in $deps; do
    local dep_name dep_ver
    dep_name=$(echo "$dep" | cut -d'>' -f1 | cut -d'=' -f1)
    dep_ver=$(echo "$dep" | grep -oE '[0-9.]+$')

    # evitar ciclos
    if echo "$stack" | grep -q "|$dep_name|"; then
      err "Ciclo detectado: $stack -> $dep_name"
      return 1
    fi

    # resolver recursivo
    resolve_all "$dep_name" "$seen|$port_path|" "$stack|$port_path|" || return 1

    # instalar/atualizar
    if ! is_installed "$dep_name"; then
      log_info "[$type] Instalando $dep_name"
      cmd_install "$dep_name" || return 1
    else
      if [ -n "$dep_ver" ]; then
        local inst_ver
        inst_ver=$(get_installed_version "$dep_name")
        if ! version_ge "$inst_ver" "$dep_ver"; then
          log_warn "[$type] $dep_name na versão $inst_ver, requer >= $dep_ver"
          cmd_upgrade "$dep_name" || return 1
        fi
      fi
    fi
  done
}

# Resolve todos os tipos de dependência
resolve_all() {
  local port_path="$1"
  local seen="$2"
  local stack="$3"

  # cache
  local cache_file="$DEPS_CACHE/$(echo "$port_path" | tr '/' '_').dep"
  if [ -f "$cache_file" ]; then
    log_debug "Usando cache de dependências para $port_path"
    return 0
  fi

  log_info "Resolvendo dependências de $port_path"

  resolve_type "$port_path" "BUILD_DEPENDS" "$seen" "$stack" || return 1
  resolve_type "$port_path" "RUN_DEPENDS"   "$seen" "$stack" || return 1
  resolve_type "$port_path" "TEST_DEPENDS"  "$seen" "$stack" || return 1

  echo "resolved $(date)" > "$cache_file"

  # gerar lockfile
  local lockfile="$PORTSDIR/$port_path/DEPENDENCIES.lock"
  {
    echo "# Gerado em $(date)"
    echo "BUILD_DEPENDS=$(get_depends "$port_path" "BUILD_DEPENDS")"
    echo "RUN_DEPENDS=$(get_depends "$port_path" "RUN_DEPENDS")"
    echo "TEST_DEPENDS=$(get_depends "$port_path" "TEST_DEPENDS")"
  } > "$lockfile"
}

# Imprime árvore de dependências
print_dep_tree() {
  local port_path="$1"
  local indent="$2"

  echo "${indent}${port_path}"
  for type in BUILD_DEPENDS RUN_DEPENDS TEST_DEPENDS; do
    local deps
    deps=$(get_depends "$port_path" "$type")
    for dep in $deps; do
      print_dep_tree "$dep" "  $indent"
    done
  done
}

# CLI
cmd_deps() {
  local port_path="$1"; shift
  [ -n "$port_path" ] || { err "Uso: package deps <port> [tree]"; return 2; }

  case "$1" in
    tree)
      log_info "Árvore de dependências de $port_path:"
      print_dep_tree "$port_path" "  "
      ;;
    *)
      resolve_all "$port_path" "|" "|" || return 1
      log_info "Dependências resolvidas para $port_path"
      ;;
  esac
}
