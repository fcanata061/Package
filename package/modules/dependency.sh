#!/usr/bin/env bash
# package/modules/dependency.sh (revisado e integrado)
# Gerencia dependências de ports (BUILD_DEPENDS, RUN_DEPENDS etc.)
# Expõe: cmd_deps, resolve_and_install_deps

set -euo pipefail

[ -f /etc/package.conf ] && source /etc/package.conf || true

PORTSDIR=${PORTSDIR:-/usr/ports}
REGISTRY_DIR=${REGISTRY_DIR:-/var/lib/package/registry}
FILES_DIR=${FILES_DIR:-/var/lib/package/files}
DEP_LOG_DIR=${DEP_LOG_DIR:-/var/log/package/deps}
PARALLEL_JOBS=${PARALLEL_JOBS:-1}

mkdir -p "$DEP_LOG_DIR" "$REGISTRY_DIR" "$FILES_DIR"

# Logging
: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_error:=:}"

if ! declare -F log_info >/dev/null; then log_info(){ echo "[deps][INFO] $*"; }; fi
if ! declare -F log_warn >/dev/null; then log_warn(){ echo "[deps][WARN] $*"; }; fi
if ! declare -F log_error >/dev/null; then log_error(){ echo "[deps][ERROR] $*" >&2; }; fi

# Load auxiliary modules
MODULE_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
[ -f "$MODULE_DIR/register.sh" ] && source "$MODULE_DIR/register.sh"
[ -f "$MODULE_DIR/build.sh" ] && source "$MODULE_DIR/build.sh"
[ -f "$MODULE_DIR/install.sh" ] && source "$MODULE_DIR/install.sh"
[ -f "$MODULE_DIR/update.sh" ] && source "$MODULE_DIR/update.sh"

# Fallbacks se funções ausentes

if ! declare -F register_is_installed >/dev/null; then
  register_is_installed() {
    local category_name="$1"
    local portkey="${category_name//\//_}"
    [ -f "${REGISTRY_DIR}/${portkey}.json" ]
  }
fi

if ! declare -F get_installed_version >/dev/null; then
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
fi

if ! declare -F cmd_install >/dev/null; then
  cmd_install() {
    log_error "cmd_install não disponível — integre install.sh"
    return 2
  }
fi

if ! declare -F cmd_upgrade >/dev/null; then
  cmd_upgrade() {
    log_error "cmd_upgrade não disponível — upgrade automático não possível"
    return 2
  }
fi

# Versão / comparação de versão
_vnorm() { printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
version_ge() {
  local v1=$(_vnorm "$1"); local v2=$(_vnorm "$2")
  if [ -z "$v2" ]; then return 0; fi
  [ "$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | head -n1)" = "$v2" ]
}
version_eq() {
  [ "$(_vnorm "$1")" = "$(_vnorm "$2")" ]
}
version_satisfies() {
  local inst="$(_vnorm "$1")" op="$2" req="$(_vnorm "$3")"
  [ -z "$op" ] && return 0
  case "$op" in
    ">=") version_ge "$inst" "$req" ;;
    "<=") version_ge "$req" "$inst" ;;
    "=") version_eq "$inst" "$req" ;;
    ">") version_ge "$inst" "$req" && ! version_eq "$inst" "$req" ;;
    "<") version_ge "$req" "$inst" && ! version_eq "$inst" "$req" ;;
    *) return 1 ;;
  esac
}

# Parse Makefile helpers
_makefile_var() {
  local port="$1" var="$2"
  local mf="$PORTSDIR/$port/Makefile"
  [ -f "$mf" ] || return 1
  awk -v v="$var" '
    $0 ~ "^[[:space:]]*"v"[[:space:]]*[:=+]" {
      line=$0
      # juntar continuations
      while (sub(/\\$/,"",line) && getline nx && /^[[:space:]]+/) {
        line=line nx
      }
      sub("^[[:space:]]*"v"[[:space:]]*[:=+][[:space:]]*","",line)
      gsub(/^[[:space:]]+/,"",line)
      gsub(/[[:space:]]+$/,"",line)
      print line
      exit
    }
  ' "$mf" | sed 's/#.*//'
}

# Tokenizar dependências, parse versão
_tokenize_deps() {
  local s="$*"
  for t in $s; do echo "$t"; done
}

_parse_dep_token() {
  local tok="$1"
  if [[ "$tok" =~ ^([^><=]+)(>=|<=|=|>|<)(.+)$ ]]; then
    printf '%s\t%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
  else
    printf '%s\t%s\t%s\n' "$tok" "" ""
  fi
}

# Grafo de dependências
declare -A _adj _indeg _nodes _reqver

_graph_reset() {
  _adj=(); _indeg=(); _nodes=(); _reqver=()
}

_graph_add_node() {
  local n="$1"
  _nodes["$n"]=1
  [ -n "${_adj[$n]:-}" ] || _adj["$n"]=""
  [ -n "${_indeg[$n]:-}" ] || _indeg["$n"]=0
}

_graph_add_edge() {
  local from="$1" to="$2"
  _graph_add_node "$from"
  _graph_add_node "$to"
  if [[ " ${_adj[$from]} " != *" $to "* ]]; then
    _adj["$from"]="${_adj[$from]} $to"
    _indeg["$to"]=$(( ${_indeg["$to"]} + 1 ))
  fi
}

# Construir grafo recursivo
_build_graph_recursive() {
  local port="$1"
  local seen="$2"
  [[ "$seen" == *"|$port|"* ]] && return 0
  seen="$seen|$port|"
  _graph_add_node "$port"
  local bstr rstr tok nm op ver

  bstr=$(_makefile_var "$port" "BUILD_DEPENDS" 2>/dev/null || true)
  rstr=$(_makefile_var "$port" "RUN_DEPENDS" 2>/dev/null || true)

  for tok in $(_tokenize_deps $bstr); do
    IFS=$'\t' read -r nm op ver < <(_parse_dep_token "$tok")
    [ -n "$op" ] && [ -n "$ver" ] && [ -z "${_reqver[$nm]:-}" ] && _reqver["$nm"]="${op}${ver}"
    _graph_add_edge "$port" "$nm"
    _build_graph_recursive "$nm" "$seen"
  done

  for tok in $(_tokenize_deps $rstr); do
    IFS=$'\t' read -r nm op ver < <(_parse_dep_token "$tok")
    [ -n "$op" ] && [ -n "$ver" ] && [ -z "${_reqver[$nm]:-}" ] && _reqver["$nm"]="${op}${ver}"
    _graph_add_edge "$port" "$nm"
    _build_graph_recursive "$nm" "$seen"
  done
}

# Detectar ciclo
_detect_cycle_dfs() {
  local _cycle_found=0
  local _cycle_path=""
  declare -Ag _visited

  for n in "${!_nodes[@]}"; do unset _visited["$n"]; done

  _dfs_visit() {
    local node="$1"
    local stack="$2"
    stack="$stack|$node|"
    _visited["$node"]=1
    for nb in ${_adj[$node]}; do
      if [[ "$stack" == *"|$nb|"* ]]; then
        _cycle_found=1
        _cycle_path="$stack$nb|"
        return 0
      fi
      if [ -z "${_visited[$nb]:-}" ]; then
        _dfs_visit "$nb" "$stack" || return 0
      fi
      [ "$_cycle_found" -eq 1 ] && return 0
    done
  }

  for n in "${!_nodes[@]}"; do
    if [ -z "${_visited[$n]:-}" ]; then
      _dfs_visit "$n" "|"
      [ "$_cycle_found" -eq 1 ] && break
    fi
  done

  if [ "$_cycle_found" -eq 1 ]; then
    local p="${_cycle_path#|}"
    p="${p%|}"
    IFS='|' read -r -a arr <<< "$p"
    local out=""
    for x in "${arr[@]}"; do [ -z "$x" ] && continue; out="${out}${x} -> "; done
    out="${out% -> }"
    log_error "Ciclo de dependência detectado: $out"
    return 1
  fi
  return 0
}

# Topological sort (Kahn)
topo_sort() {
  local -A indeg_copy
  local -a zeroq order

  for n in "${!_nodes[@]}"; do
    indeg_copy["$n"]=${_indeg["$n"]:-0}
  done

  for n in "${!_nodes[@]}"; do
    if [ "${indeg_copy[$n]}" -eq 0 ]; then
      zeroq+=("$n")
    fi
  done

  while [ "${#zeroq[@]}" -gt 0 ]; do
    local h="${zeroq[0]}"
    zeroq=("${zeroq[@]:1}")
    order+=("$h")
    for nb in ${_adj[$h]}; do
      indeg_copy["$nb"]=$(( indeg_copy["$nb"] - 1 ))
      if [ "${indeg_copy[$nb]}" -eq 0 ]; then
        zeroq+=("$nb")
      fi
    done
  done

  # checar ciclos
  for n in "${!_nodes[@]}"; do
    if [ "${indeg_copy[$n]:-0}" -gt 0 ]; then
      log_error "topo_sort: ciclo detectado"
      return 1
    fi
  done

  for n in "${order[@]}"; do
    printf '%s\n' "$n"
  done
}

# Ensure dependência instalada ou versão compatível
ensure_node_satisfied() {
  local node="$1"
  local no_upgrade="$2"
  local req="${_reqver[$node]:-}"
  local inst

  if register_is_installed "$node"; then
    inst="$(get_installed_version "$node")"
    if [ -n "$req" ]; then
      # separa op e versão
      if [[ "$req" =~ ^(>=|<=|=|>|<)(.+)$ ]]; then
        local op="${BASH_REMATCH[1]}"
        local ver="${BASH_REMATCH[2]}"
        if version_satisfies "$inst" "$op" "$ver"; then
          log_info "Instalada versão de $node ($inst) satisfaz $op$ver"
          return 0
        else
          log_warn "Versão instalada de $node ($inst) NÃO satisfaz $op$ver"
          if [ "$no_upgrade" = "1" ]; then
            log_error "Política --no-upgrade ativa; abortando dependência $node"
            return 2
          fi
          # tentar upgrade
          log_info "Tentando atualizar $node via cmd_upgrade..."
          cmd_upgrade "$node" || { log_error "cmd_upgrade falhou para $node"; return 1; }
          # re-obter versão
          inst="$(get_installed_version "$node")"
          if version_satisfies "$inst" "$op" "$ver"; then
            log_info "Upgrade bem-sucedido de $node -> $inst"
            return 0
          else
            log_error "Após upgrade, $node ($inst) ainda não satisfaz $op$ver"
            return 1
          fi
        fi
      else
        log_warn "Requisito de versão malformado para $node: $req"
        return 0
      fi
    else
      log_info "$node instalado; versão $inst"
      return 0
    fi
  else
    log_info "$node não está instalado; instalando via cmd_install"
    cmd_install "$node" || { log_error "cmd_install falhou para $node"; return 1; }
    return 0
  fi
}

# Resolve dependências recursivamente e instala conforme topo order
resolve_and_install_deps() {
  local root="$1"
  local dry="${2:-}"
  local no_upgrade="${3:-}"
  build_graph "$root"
  _detect_cycle_dfs || return 1
  local -a order
  while IFS= read -r n; do order+=("$n"); done < <(topo_sort) || return 1
  local -a install_order
  for (( i=${#order[@]}-1; i>=0; i-- )); do install_order+=("${order[i]}"); done
  log_info "Ordem para instalação de dependências: ${install_order[*]}"
  if [ "$dry" = "--dry-run" ]; then
    log_info "Dry-run ativado: nenhuma ação efetiva será tomada"
    return 0
  fi
  for node in "${install_order[@]}"; do
    ensure_node_satisfied "$node" "${no_upgrade:-0}" || return 1
  done
  return 0
}

# Interface pública
cmd_deps() {
  local port="$1"
  local action="${2:-topo}"
  local flag3="$3"
  [ -n "$port" ] || { log_error "Uso: package deps <category/name> [tree|topo|graphviz|install|dry-run] [--no-upgrade]"; return 2; }

  build_graph "$port"

  case "$action" in
    tree) print_tree "$port" ;;
    topo) topo_sort ;;
    graphviz) graphviz_dot ;;
    install) resolve_and_install_deps "$port" "" "${flag3:-}" ;;
    dry-run) resolve_and_install_deps "$port" "--dry-run" "${flag3:-}" ;;
    *) log_error "Ação desconhecida: $action"; return 2 ;;
  esac
}

export -f cmd_deps resolve_and_install_deps build_graph topo_sort graphviz_dot
