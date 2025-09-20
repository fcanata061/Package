#!/usr/bin/env bash
# modules/dependency.sh
# Gerenciamento avançado de dependências com grafo e ordenação topológica
#
# Funções expostas:
#  - cmd_deps <categoria/port> [tree|topo|graphviz|install|dry-run]
#  - resolve_and_install_deps <categoria/port> [--dry-run]
#
# Dependências externas esperadas:
#  - register_is_installed <categoria/port> -> retorna 0 se instalado
#  - cmd_build <categoria/port> -> constrói/instala o port
#
# Variáveis:
#  PORTSDIR, DEP_LOG_DIR, PARALLEL_JOBS

PORTSDIR=${PORTSDIR:-/usr/ports}
DEP_LOG_DIR=${DEP_LOG_DIR:-/var/log/package/deps}
PARALLEL_JOBS=${PARALLEL_JOBS:-1}

mkdir -p "$DEP_LOG_DIR"

# fallbacks de logging
: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_error:=:}"
: "${register_is_installed:=:}"
: "${cmd_build:=:}"

if ! declare -F log_info >/dev/null; then log_info(){ echo "[deps][INFO] $*"; }; fi
if ! declare -F log_warn >/dev/null; then log_warn(){ echo "[deps][WARN] $*"; }; fi
if ! declare -F log_error >/dev/null; then log_error(){ echo "[deps][ERROR] $*" >&2; }; fi
if ! declare -F register_is_installed >/dev/null; then
  register_is_installed(){ return 1; } # assume not installed if not provided
fi
if ! declare -F cmd_build >/dev/null; then
  cmd_build(){ log_error "cmd_build não disponível: integrar com build.sh"; return 2; }
fi

# -------------------- utilitários --------------------

# Extrai valor de variável do Makefile (suporta continuação com \)
_makefile_var() {
  local port="$1" var="$2"
  local mf="$PORTSDIR/$port/Makefile"
  [ -f "$mf" ] || return 1
  # pega linhas que começam com VAR= e junta continuations
  awk -v v="$var" '
    BEGIN{out=""; inblock=0}
    $0 ~ "^[[:space:]]*"v"[[:space:]]*=" {
      sub("^[[:space:]]*"v"[[:space:]]*=","");
      line=$0;
      # accumulate continuation lines ending with \
      while (line ~ /\\$/) {
        sub(/\\$/,"",line);
        out=out line;
        if (getline next) { line = next } else { break }
      }
      out=out line;
      gsub(/[[:space:]]+$/, "", out);
      gsub(/^[[:space:]]+/, "", out);
      print out;
    }' "$mf" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed 's/#.*//'
}

# Tokeniza uma string de dependências em tokens por whitespace
_tokenize_deps() {
  local s="$*"
  # remove múltiplos espaços e quebra em tokens
  # preserve slash and operators in token
  for tok in $s; do
    echo "$tok"
  done
}

# Parse token: retorna "name op ver"
# exemplos:
#   devel/libfoo>=1.2  -> devel/libfoo >= 1.2
#   editors/vim         -> editors/vim  ""  ""
_parse_dep_token() {
  local tok="$1"
  if [[ "$tok" =~ ^([^><=]+)(>=|<=|=|>|<)(.+)$ ]]; then
    printf '%s\t%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
  else
    printf '%s\t%s\t%s\n' "$tok" "" ""
  fi
}

# -------------------- grafo (associative arrays) --------------------
# usamos Bash associative arrays; requer bash >=4
declare -A _adj    # adjacency: node -> "n1 n2 n3"
declare -A _indeg  # indegree: node -> number
declare -A _nodes  # set: node -> 1
declare -A _ver    # node -> requested version (if any), e.g. ">=1.2"

_graph_reset() {
  _adj=()
  _indeg=()
  _nodes=()
  _ver=()
}

_graph_add_node() {
  local n="$1"
  _nodes["$n"]=1
  [ -n "${_adj[$n]:-}" ] || _adj["$n"]=""
  [ -n "${_indeg[$n]:-}" ] || _indeg["$n"]=0
}

_graph_add_edge() {
  local from="$1" to="$2"
  # add nodes
  _graph_add_node "$from"
  _graph_add_node "$to"
  # append to adjacency if not already present
  if [[ " ${_adj[$from]} " != *" $to "* ]]; then
    _adj["$from"]="${_adj[$from]} $to"
    _indeg["$to"]=$(( ${_indeg["$to"]} + 1 ))
  fi
}

# -------------------- construir grafo recursivamente --------------------
# build_graph <root>
# - percorre dependências (BUILD_DEPENDS e RUN_DEPENDS) e popula _adj/_nodes/_ver
_build_graph_recursive() {
  local port="$1"
  local seen="$2"  # pipe-delimited seen list to avoid revisiting

  # detect revisit
  if [[ "$seen" == *"|$port|"* ]]; then
    return 0
  fi
  seen="$seen|$port|"

  # add node for port
  _graph_add_node "$port"

  # read build deps
  local bstr rstr tok name op ver
  bstr=$(_makefile_var "$port" "BUILD_DEPENDS" 2>/dev/null || true)
  rstr=$(_makefile_var "$port" "RUN_DEPENDS" 2>/dev/null || true)

  for tok in $(_tokenize_deps $bstr); do
    IFS=$'\t' read -r name op ver < <(_parse_dep_token "$tok")
    # store version requirement if present (only first wins)
    if [ -n "$op" ] && [ -n "$ver" ] && [ -z "${_ver[$name]:-}" ]; then
      _ver["$name"]="${op}${ver}"
    fi
    _graph_add_edge "$port" "$name"
    _build_graph_recursive "$name" "$seen"
  done

  for tok in $(_tokenize_deps $rstr); do
    IFS=$'\t' read -r name op ver < <(_parse_dep_token "$tok")
    if [ -n "$op" ] && [ -n "$ver" ] && [ -z "${_ver[$name]:-}" ]; then
      _ver["$name"]="${op}${ver}"
    fi
    _graph_add_edge "$port" "$name"
    _build_graph_recursive "$name" "$seen"
  done
}

# Public API: build_graph <root>
build_graph() {
  local root="$1"
  _graph_reset
  _build_graph_recursive "$root" "|"
}

# -------------------- detectar ciclo via DFS (branco/cinza/preto) --------------------
# retorna 0 se sem ciclos, 1 se ciclo detectado (e imprime a cadeia)
_detect_cycle_dfs() {
  local node="$1"
  declare -A seen_local
  # We'll implement DFS iteratively with stacks to produce path on cycle detection
  # but simpler - recursive helper:
  _cycle_found=0
  _cycle_path=""

  _dfs_visit() {
    local n="$1"
    local stack="$2"
    # mark gray by adding to stack
    stack="$stack|$n"
    # iterate adjacency
    local neigh
    for neigh in ${_adj[$n]}; do
      # if neigh is already in stack -> cycle
      if [[ "$stack" == *"|$neigh|"* ]]; then
        _cycle_found=1
        _cycle_path="$stack|$neigh|"
        return 0
      fi
      # if not visited (we track visited in global _visited)
      if [ -z "${_visited[$neigh]:-}" ]; then
        _visited["$neigh"]=1
        _dfs_visit "$neigh" "$stack" || return 0
        [ $_cycle_found -eq 1 ] && return 0
      fi
    done
  }

  # initialize visited array
  declare -Ag _visited
  for n in "${!_nodes[@]}"; do
    unset _visited["$n"]
  done

  for n in "${!_nodes[@]}"; do
    if [ -z "${_visited[$n]:-}" ]; then
      _visited["$n"]=1
      _dfs_visit "$n" "|$n|" || true
      if [ $_cycle_found -eq 1 ]; then
        # print cycle nicely
        local p="${_cycle_path#|}"
        p="${p%|}"
        # convert to -> sequence
        local out=""
        IFS='|' read -r -a arr <<< "$p"
        for i in "${arr[@]}"; do
          [ -z "$i" ] && continue
          if [ -z "$out" ]; then out="$i"; else out="$out -> $i"; fi
        done
        log_error "Ciclo de dependência detectado: $out"
        return 1
      fi
    fi
  done
  return 0
}

# -------------------- ordenação topológica (Kahn) --------------------
# topo_sort -> prints one node per line in install order (dependencies first)
topo_sort() {
  local -A indeg_copy
  local -a zeroq
  local n q head i out
  # copy indegree
  for n in "${!_nodes[@]}"; do indeg_copy["$n"]=${_indeg["$n"]:-0}; done

  # push nodes with indeg 0
  for n in "${!_nodes[@]}"; do
    if [ "${indeg_copy[$n]}" -eq 0 ]; then
      zeroq+=("$n")
    fi
  done

  while [ "${#zeroq[@]}" -gt 0 ]; do
    # pop head
    head="${zeroq[0]}"
    zeroq=("${zeroq[@]:1}")
    printf '%s\n' "$head"
    # for each neighbor, decrement indeg
    for i in ${_adj[$head]}; do
      indeg_copy["$i"]=$(( indeg_copy["$i"] - 1 ))
      if [ "${indeg_copy[$i]}" -eq 0 ]; then
        zeroq+=("$i")
      fi
    done
  done

  # check if any node still has indeg > 0 => cycle
  for n in "${!_nodes[@]}"; do
    if [ "${indeg_copy[$n]}" -gt 0 ]; then
      log_error "Impossível ordenar topo: ciclo detectado (nodo com indegree > 0)"
      return 1
    fi
  done

  return 0
}

# -------------------- util: imprimir árvore (dfs) --------------------
_print_tree_recursive() {
  local node="$1" indent="$2" seen="$3"
  if [[ "$seen" == *"|$node|"* ]]; then
    printf "%s%s (already shown)\n" "$indent" "$node"
    return
  fi
  seen="$seen|$node|"
  printf "%s%s\n" "$indent" "$node"
  for c in ${_adj[$node]}; do
    _print_tree_recursive "$c" "  $indent" "$seen"
  done
}

print_tree() {
  local root="$1"
  _print_tree_recursive "$root" "" "|"
}

# -------------------- util: output graphviz DOT --------------------
graphviz_dot() {
  echo "digraph deps {"
  echo "  node [shape=box];"
  for n in "${!_nodes[@]}"; do
    local label="$n"
    if [ -n "${_ver[$n]:-}" ]; then label="$label\\n(${_ver[$n]})"; fi
    printf '  "%s" [label="%s"];\n' "$n" "$label"
  done
  for n in "${!_nodes[@]}"; do
    for c in ${_adj[$n]}; do
      printf '  "%s" -> "%s";\n' "$n" "$c"
    done
  done
  echo "}"
}

# -------------------- resolver e instalar na ordem topológica --------------------
# resolve_and_install_deps <root> [--dry-run]
resolve_and_install_deps() {
  local root="$1"
  local dry="${2:-}"
  build_graph "$root"

  # detect cycles
  _detect_cycle_dfs >/dev/null 2>&1 || return 1

  # get topo order into array (dependencies last printed? We print nodes such that
  # dependencies come after edges from parent to dep; but we built edges port->dep,
  # so topo_sort will produce nodes with no deps first (leafs). For installation
  # we want to install dependencies before dependents; so we will reverse the topo result.)
  local -a order
  while IFS= read -r n; do order+=("$n"); done < <(topo_sort) || return 1

  # reverse order so dependencies installed first
  local -a install_order
  for (( idx=${#order[@]}-1; idx>=0; idx-- )); do
    install_order+=("${order[idx]}")
  done

  # filter out the root itself from installing if desired? Usually we install deps then root.
  # We'll install all nodes in install_order but skip nodes already installed.
  log_info "Ordem de instalação (dependencies first):"
  local idx node
  for idx in "${!install_order[@]}"; do
    node="${install_order[$idx]}"
    printf "%3d. %s" "$((idx+1))" "$node"
    if register_is_installed "$node"; then
      printf " (already installed)\n"
      continue
    else
      printf "\n"
    fi
  done

  if [ "$dry" = "--dry-run" ]; then
    log_info "Dry-run: não será instalada nenhuma dependência."
    return 0
  fi

  # Install sequentially (could be parallelized with care)
  for node in "${install_order[@]}"; do
    if register_is_installed "$node"; then
      log_info "Pular $node — já instalado"
      continue
    fi
    log_info "Instalando $node ..."
    if ! cmd_build "$node"; then
      log_error "Falha ao instalar dependência $node"
      return 1
    fi
    log_info "Instalado: $node"
  done

  return 0
}

# -------------------- CLI --------------------
cmd_deps() {
  local port="$1"
  local action="${2:-topo}" # default topo
  [ -n "$port" ] || { log_error "Uso: package deps <categoria/port> [tree|topo|graphviz|install|dry-run]"; return 2; }

  build_graph "$port"

  case "$action" in
    tree)
      print_tree "$port"
      ;;
    topo)
      topo_sort
      ;;
    graphviz)
      graphviz_dot
      ;;
    install)
      resolve_and_install_deps "$port"
      ;;
    dry-run)
      resolve_and_install_deps "$port" "--dry-run"
      ;;
    *)
      log_error "Ação desconhecida: $action"
      return 2
      ;;
  esac
}

# expose functions if sourced
export -f cmd_deps build_graph topo_sort graphviz_dot resolve_and_install_deps
