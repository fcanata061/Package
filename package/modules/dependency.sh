#!/usr/bin/env bash
# modules/dependency.sh
# Gerenciamento avançado de dependências (completo e funcional)
#
# Funcionalidades:
#  - Suporta BUILD_DEPENDS, RUN_DEPENDS, TEST_DEPENDS
#  - Suporta operadores de versão: >=, <=, =, >, <
#  - Resolução recursiva com detecção de ciclos
#  - Cache em /var/lib/package/deps
#  - Lockfile em /usr/ports/<port>/DEPENDENCIES.lock
#  - Comandos: package deps <port> | tree | clean-cache | show-lock
#
# Uso esperado:
#   colocar no MODULEDIR e ser `source`'ado pelo CLI principal
#
# Variáveis (podem ser definidas em /etc/package.conf):
#  PORTSDIR, INSTALLED_DB, DEPS_CACHE

# --------- Configurações padrão (sobrescreva em /etc/package.conf) ----------
PORTSDIR=${PORTSDIR:-/usr/ports}
INSTALLED_DB=${INSTALLED_DB:-/var/lib/package/installed}
DEPS_CACHE=${DEPS_CACHE:-/var/lib/package/deps}
LOCKFILE_NAME=DEPENDENCIES.lock

mkdir -p "$DEPS_CACHE"
mkdir -p "$(dirname "$INSTALLED_DB")"
touch "$INSTALLED_DB"

# --------- Fallbacks para logging / ações se não existirem ----------
: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_debug:=:}"
: "${err:=:}"

# Se as funções não existem, definimos versões simples
if ! declare -F log_info >/dev/null; then
  log_info() { echo "[INFO] $*"; }
fi
if ! declare -F log_warn >/dev/null; then
  log_warn() { echo "[WARN] $*"; }
fi
if ! declare -F log_debug >/dev/null; then
  # debug only if env var DEBUG=1
  log_debug() { [ "${DEBUG:-0}" -eq 1 ] && echo "[DEBUG] $*"; }
fi
if ! declare -F err >/dev/null; then
  err() { echo "[ERROR] $*" >&2; }
fi

# Funções que o módulo espera encontrar (instalador / upgrade).
# Se não existirem no ambiente, criamos stubs que falham com mensagem.
if ! declare -F is_installed >/dev/null; then
  is_installed() { grep -q "^$1 " "$INSTALLED_DB" 2>/dev/null || return 1; }
fi
if ! declare -F cmd_install >/dev/null; then
  cmd_install() { err "cmd_install não disponível: tente integrar dependency.sh com install.sh"; return 2; }
fi
if ! declare -F cmd_upgrade >/dev/null; then
  cmd_upgrade() { err "cmd_upgrade não disponível: tente integrar dependency.sh com upgrade.sh"; return 2; }
fi

# ------------------ Utilitários para versões ------------------
# version_ge v1 v2 -> retorna 0 se v1 >= v2
version_ge() {
  local v1="$1" v2="$2"
  # se um dos dois vazio, considera verdadeiro somente se v2 vazio
  [ -z "$v2" ] && return 0
  [ -z "$v1" ] && return 1
  [ "$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | head -n1)" = "$v2" ]
}

# version_eq v1 v2 -> 0 se igual
version_eq() {
  [ "$1" = "$2" ]
}

# version_cmp v1 op v2 -> aceita ops: >= <= = > <
version_satisfies() {
  local v1="$1" op="$2" v2="$3"
  case "$op" in
    ">=") version_ge "$v1" "$v2" ;;
    "<=") version_ge "$v2" "$v1" ;;
    "=")  version_eq "$v1" "$v2" ;;
    ">")  version_ge "$v1" "$v2" && ! version_eq "$v1" "$v2" ;;
    "<")  version_ge "$v2" "$v1" && ! version_eq "$v1" "$v2" ;;
    *)
      # no operator means any version ok
      return 0
      ;;
  esac
}

# ------------------ Parser de dependências do Makefile ------------------
# Retorna linhas tokenizadas (uma dependência por linha), preservando slash
# get_depends <port_path> <TYPE>
get_depends() {
  local port_path="$1"
  local type="$2" # BUILD_DEPENDS, RUN_DEPENDS, TEST_DEPENDS
  local makefile="$PORTSDIR/$port_path/Makefile"
  [ -f "$makefile" ] || return 0

  # Extrair conteúdo (suporta várias linhas se Makefile usar `\`)
  # Remove comentários (#...) e concatena linhas com \ ao final
  local content
  content=$(awk '
    BEGIN{ORS="";}
    /^#/ {next}
    { line=$0
      if (sub(/^[[:space:]]*'"$type"'[[:space:]]*=[[:space:]]*/, "", line)) {
         # accumulate line and following continuation lines
         val=line
         while (val ~ /\\$/) {
           sub(/\\$/,"",val)
           if (getline nextline) { val = val nextline } else break
         }
         # print and newline separator
         gsub(/^[[:space:]]+/,"",val)
         gsub(/[[:space:]]+$/,"",val)
         print val "\n"
      }
    }' "$makefile")

  # content may contain multiple token sequences; split by whitespace
  # we want each token in a new line
  if [ -n "$content" ]; then
    # replace commas by spaces, then split by whitespace into lines
    echo "$content" | tr ',' ' ' | xargs -n1
  fi
}

# Parse token like: category/name>=1.2  OR category/name  OR category/name=1.2
# retorna: nome operador versao
# parse_dep "devel/libfoo>=1.2"
parse_dep() {
  local token="$1"
  local name op ver

  # detectar operador (>=, <=, =, >, <)
  if [[ "$token" =~ ^([^><=]+)(>=|<=|=|>|<)(.+)$ ]]; then
    name="${BASH_REMATCH[1]}"
    op="${BASH_REMATCH[2]}"
    ver="${BASH_REMATCH[3]}"
  else
    name="$token"
    op=""
    ver=""
  fi

  # trim
  name="${name## }"
  name="${name%% }"
  echo "$name" "$op" "$ver"
}

# ------------------ Cache / Lockfile ------------------
cache_file_for() {
  local port_path="$1"
  echo "$DEPS_CACHE/$(echo "$port_path" | tr '/' '_').dep"
}

lockfile_for() {
  local port_path="$1"
  echo "$PORTSDIR/$port_path/$LOCKFILE_NAME"
}

# Remove cache for port
clean_cache_for() {
  local port="$1"
  local cf
  cf=$(cache_file_for "$port")
  [ -f "$cf" ] && rm -f "$cf"
}

# ------------------ Resolução recursiva ------------------
# resolve_all <port> <seen_string> <stack_string>
# seen_string and stack_string are pipe-delimited lists like |a|b|
resolve_all() {
  local port_path="$1"
  local seen="$2"
  local stack="$3"

  # normalize
  seen="${seen:-|}"
  stack="${stack:-|}"

  # detect cycle
  if echo "$stack" | grep -q "|$port_path|"; then
    err "Ciclo de dependência detectado: $stack -> $port_path"
    return 1
  fi

  # if already processed in this run, skip
  if echo "$seen" | grep -q "|$port_path|"; then
    log_debug "Já processado (cache run): $port_path"
    return 0
  fi

  # if cached resolution exists, we still must ensure dependencies installed
  local cf
  cf=$(cache_file_for "$port_path")
  if [ -f "$cf" ]; then
    log_debug "Usando cache para $port_path: $cf"
    # we still read lockfile to know what to ensure installed
    local lockf
    lockf=$(lockfile_for "$port_path")
    if [ -f "$lockf" ]; then
      # read lockfile and install entries (RUN + BUILD)
      while IFS= read -r line; do
        case "$line" in
          BUILD_DEPENDS=*|RUN_DEPENDS=*|TEST_DEPENDS=*)
            local lhs rhs
            lhs="${line%%=*}"
            rhs="${line#*=}"
            for tok in $rhs; do
              # parse
              read -r dep_name dep_op dep_ver <<< "$(parse_dep "$tok")"
              ensure_dep_installed "$dep_name" "$dep_op" "$dep_ver" || return 1
            done
            ;;
          *) ;;
        esac
      done < "$lockf"
    fi
    # mark as seen in this run
    seen="$seen$port_path|"
    return 0
  fi

  log_info "Resolvendo dependências de $port_path"
  # for each type, parse deps and recurse
  for TYPE in BUILD_DEPENDS RUN_DEPENDS TEST_DEPENDS; do
    local deps
    deps=$(get_depends "$port_path" "$TYPE")
    for token in $deps; do
      read -r dep_name dep_op dep_ver <<< "$(parse_dep "$token")"
      # recursion
      resolve_all "$dep_name" "$seen$port_path|" "$stack$port_path|" || return 1
      # ensure installed / version satisfied
      ensure_dep_installed "$dep_name" "$dep_op" "$dep_ver" || return 1
    done
  done

  # mark cache file to speed future runs
  echo "resolved: $(date --iso-8601=seconds 2>/dev/null || date)" > "$cf"
  # write lockfile
  local lockf
  lockf=$(lockfile_for "$port_path")
  {
    echo "# $LOCKFILE_NAME - gerado por dependency.sh em $(date --iso-8601=seconds 2>/dev/null || date)"
    for TYPE in BUILD_DEPENDS RUN_DEPENDS TEST_DEPENDS; do
      echo -n "${TYPE}="
      get_depends "$port_path" "$TYPE" | xargs 2>/dev/null || true
      echo
    done
  } > "$lockf" 2>/dev/null || {
    # fallback se diretório do port não existe (silencioso)
    log_debug "Não foi possível escrever lockfile $lockf (diretório pode não existir)"
  }

  return 0
}

# ensure_dep_installed <name> <op> <ver>
ensure_dep_installed() {
  local name="$1" op="$2" ver="$3"

  if ! is_installed "$name"; then
    log_info "Instalando dependência: $name ${op:+$op$ver}"
    cmd_install "$name" || return 1
    return 0
  fi

  if [ -n "$op" ] && [ -n "$ver" ]; then
    # get installed version from INSTALLED_DB format: "port_path version extra..."
    local inst_ver
    inst_ver=$(grep "^$name " "$INSTALLED_DB" | awk '{print $2}' || true)
    if [ -z "$inst_ver" ]; then
      log_warn "Versão instalada de $name desconhecida; propondo upgrade"
      cmd_upgrade "$name" || return 1
    else
      if ! version_satisfies "$inst_ver" "$op" "$ver"; then
        log_warn "Dependência $name versão $inst_ver não satisfaz $op$ver -> atualizando"
        cmd_upgrade "$name" || return 1
      else
        log_debug "Dependência $name (versão $inst_ver) satisfaz $op$ver"
      fi
    fi
  else
    log_debug "Dependência $name já instalada"
  fi
  return 0
}

# ------------------ CLI functions ------------------
# cmd_deps <port> [tree|clean-cache|show-lock]
cmd_deps() {
  local port_path="$1"
  local action="${2:-resolve}"

  [ -n "$port_path" ] || { err "Uso: package deps <categoria/port> [tree|clean-cache|show-lock]"; return 2; }

  case "$action" in
    tree)
      print_dep_tree "$port_path" "" || return 1
      ;;
    clean-cache)
      clean_cache_for "$port_path"
      log_info "Cache limpo para $port_path"
      ;;
    show-lock)
      local lfn
      lfn=$(lockfile_for "$port_path")
      if [ -f "$lfn" ]; then
        cat "$lfn"
      else
        err "Lockfile não encontrado: $lfn"
        return 1
      fi
      ;;
    resolve|*)
      resolve_all "$port_path" "|" "|" || { err "Falha ao resolver dependências para $port_path"; return 1; }
      log_info "Dependências resolvidas para $port_path"
      ;;
  esac
}

# print_dep_tree: mostra árvore com indentação
print_dep_tree() {
  local port="$1"
  local indent="$2"
  indent="${indent:-}"
  echo "${indent}${port}"
  for TYPE in BUILD_DEPENDS RUN_DEPENDS TEST_DEPENDS; do
    local deps
    deps=$(get_depends "$port" "$TYPE")
    for tok in $deps; do
      read -r dep_name dep_op dep_ver <<< "$(parse_dep "$tok")"
      echo "${indent}  [${TYPE}] ${dep_name}${dep_op:+ ${dep_op}${dep_ver}}"
      print_dep_tree "$dep_name" "  $indent" || true
    done
  done
}

# Expor cmd_deps como função a ser chamada pelo CLI principal
# (o arquivo normalmente é source'd, então cmd_deps fica disponível)
