#!/usr/bin/env bash
# modules/dependency.sh
# Dependência avançada com grafo, topológica, comparação de versões e upgrade automático
#
# Expondo:
#  - cmd_deps <categoria/port> [tree|topo|graphviz|install|dry-run] [--no-upgrade]
#  - resolve_and_install_deps <categoria/port> [--dry-run] [--no-upgrade]
#
# Requisitos (funções externas esperadas; há fallbacks mínimos):
#  - register_is_installed <port>
#  - get_installed_version <port>  -> echos installed version or empty
#  - cmd_build <port>
#  - cmd_upgrade <port>            -> optional but used if present
#  - log_info/log_warn/log_error
#
# Vars: PORTSDIR, DEP_LOG_DIR, PARALLEL_JOBS

PORTSDIR=${PORTSDIR:-/usr/ports}
DEP_LOG_DIR=${DEP_LOG_DIR:-/var/log/package/deps}
PARALLEL_JOBS=${PARALLEL_JOBS:-1}

mkdir -p "$DEP_LOG_DIR"

# fallback loggers
: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_error:=:}"

if ! declare -F log_info >/dev/null; then log_info(){ echo "[deps][INFO] $*"; }; fi
if ! declare -F log_warn >/dev/null; then log_warn(){ echo "[deps][WARN] $*"; }; fi
if ! declare -F log_error >/dev/null; then log_error(){ echo "[deps][ERROR] $*" >&2; }; fi

# fallback stubs for external functions if absent
if ! declare -F register_is_installed >/dev/null; then
  register_is_installed(){ return 1; } # assume not installed
fi
if ! declare -F get_installed_version >/dev/null; then
  # fallback: try reading INSTALLED_DB file format "categoria_port" in /var/lib/package/installed/<category_port>
  get_installed_version() {
    local port="$1"
    local INSTALLED_DB=${INSTALLED_DB:-/var/lib/package/installed}
    local cat="${port%%/*}"; local name="${port##*/}"
    local file="$INSTALLED_DB/${cat}_${name}"
    if [ -f "$file" ]; then
      grep '^VERSION=' "$file" | cut -d= -f2
    else
      echo ""
    fi
  }
fi
if ! declare -F cmd_build >/dev/null; then
  cmd_build(){ log_error "cmd_build não disponível — integre build.sh"; return 2; }
fi
if ! declare -F cmd_upgrade >/dev/null; then
  # leave absent; module will error if needs to upgrade but no cmd_upgrade available
  cmd_upgrade(){ log_error "cmd_upgrade não disponível"; return 2; }
fi

# ---------------- helpers versão ----------------
# normalize version string (strip spaces)
_vnorm(){ printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

# version_ge v1 v2 -> 0 if v1 >= v2
version_ge() {
  local v1=$(_vnorm "$1"); local v2=$(_vnorm "$2")
  if [ -z "$v2" ]; then return 0; fi
  if [ -z "$v1" ]; then return 1; fi
  # use sort -V; smallest first -> if head == v2, then v2 <= v1 => v1 >= v2
  [ "$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | head -n1)" = "$v2" ]
}

version_eq(){ [ "$(_vnorm "$1")" = "$(_vnorm "$2")" ]; }

# version_satisfies installed op ver -> 0 if true
version_satisfies() {
  local inst="$(_vnorm "$1")" op="$2" req="$(_vnorm "$3")"
  [ -z "$op" ] && return 0
  case "$op" in
    ">=") version_ge "$inst" "$req" ;;
    "<=") version_ge "$req" "$inst" ;; # inst <= req -> req >= inst
    "=")  version_eq "$inst" "$req" ;;
    ">")  version_ge "$inst" "$req" && ! version_eq "$inst" "$req" ;;
    "<")  version_ge "$req" "$inst" && ! version_eq "$inst" "$req" ;;
    *)    return 1 ;;
  esac
}

# ---------------- parse Makefile deps ----------------
_makefile_var() {
  local port="$1" var="$2"
  local mf="$PORTSDIR/$port/Makefile"
  [ -f "$mf" ] || return 1
  # capture VAR=... with continuation backslashes
  awk -v v="$var" '
    $0 ~ "^[[:space:]]*"v"[[:space:]]*=" {
      sub("^[[:space:]]*"v"[[:space:]]*=","");
      val=$0;
      while (val ~ /\\$/) {
        sub(/\\$/,"",val);
        if (getline nx) val = val nx; else break;
      }
      gsub(/^[[:space:]]+/,"",val); gsub(/[[:space:]]+$/,"",val);
      print val;
    }' "$mf" | sed 's/#.*//'
}

_tokenize_deps(){ local s="$*"; for t in $s; do echo "$t"; done; }

# parse token e retorna três campos: name op ver
_parse_dep_token() {
  local tok="$1"
  if [[ "$tok" =~ ^([^><=]+)(>=|<=|=|>|<)(.+)$ ]]; then
    printf '%s\t%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
  else
    printf '%s\t%s\t%s\n' "$tok" "" ""
  fi
}

# ---------------- grafo structures ----------------
declare -A _adj _indeg _nodes _reqver
_graph_reset(){ _adj=(); _indeg=(); _nodes=(); _reqver=(); }

_graph_add_node(){
  local n="$1"; _nodes["$n"]=1
  [ -n "${_adj[$n]:-}" ] || _adj["$n"]=""
  [ -n "${_indeg[$n]:-}" ] || _indeg["$n"]=0
}

_graph_add_edge(){
  local from="$1" to="$2"
  _graph_add_node "$from"; _graph_add_node "$to"
  # avoid duplicate edge
  if [[ " ${_adj[$from]} " != *" $to "* ]]; then
    _adj["$from"]="${_adj[$from]} $to"
    _indeg["$to"]=$(( ${_indeg["$to"]} + 1 ))
  fi
}

# ---------------- build graph recusive (collect req versions) ----------------
_build_graph_recursive(){
  local port="$1"; local seen="$2"
  if [[ "$seen" == *"|$port|"* ]]; then return 0; fi
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

build_graph(){ local root="$1"; _graph_reset; _build_graph_recursive "$root" "|"; }

# ---------------- cycle detection DFS ----------------
_detect_cycle_dfs(){
  local _cycle_found=0 _cycle_path=""
  declare -Ag _visited
  for n in "${!_nodes[@]}"; do unset _visited["$n"]; done

  _dfs_visit(){
    local node="$1" stack="$2"
    stack="$stack|$node|"
    _visited["$node"]=1
    for nb in ${_adj[$node]}; do
      if [[ "$stack" == *"|$nb|"* ]]; then
        _cycle_found=1
        _cycle_path="$stack$nb|"; return 0
      fi
      if [ -z "${_visited[$nb]:-}" ]; then
        _dfs_visit "$nb" "$stack" || return 0
        [ "$_cycle_found" -eq 1 ] && return 0
      fi
    done
  }

  for n in "${!_nodes[@]}"; do
    if [ -z "${_visited[$n]:-}" ]; then
      _dfs_visit "$n" "|"
      if [ "$_cycle_found" -eq 1 ]; then
        local p="${_cycle_path#|}"; p="${p%|}"
        IFS='|' read -r -a arr <<< "$p"
        local out=""
        for x in "${arr[@]}"; do [ -z "$x" ] && continue; out="${out}${x} -> "; done
        out="${out% -> }"
        log_error "Ciclo detectado: $out"
        return 1
      fi
    fi
  done
  return 0
}

# ---------------- topo sort (Kahn) ----------------
topo_sort(){
  local -A indeg_copy; local -a zeroq order
  for n in "${!_nodes[@]}"; do indeg_copy["$n"]=${_indeg["$n"]:-0}; done
  for n in "${!_nodes[@]}"; do [ "${indeg_copy[$n]}" -eq 0 ] && zeroq+=("$n"); done
  while [ "${#zeroq[@]}" -gt 0 ]; do
    local h="${zeroq[0]}"; zeroq=("${zeroq[@]:1}")
    order+=("$h")
    for nb in ${_adj[$h]}; do
      indeg_copy["$nb"]=$(( indeg_copy["$nb"] - 1 ))
      if [ "${indeg_copy[$nb]}" -eq 0 ]; then zeroq+=("$nb"); fi
    done
  done
  # if any node still has indeg >0 -> cycle
  for n in "${!_nodes[@]}"; do
    if [ "${indeg_copy[$n]:-0}" -gt 0 ]; then log_error "topo_sort: ciclo detectado"; return 1; fi
  done
  # print order
  for n in "${order[@]}"; do printf '%s\n' "$n"; done
}

# ---------------- print tree and graphviz ----------------
_print_tree_recursive(){ local node="$1" indent="$2" seen="$3"; if [[ "$seen" == *"|$node|"* ]]; then printf "%s%s (seen)\n" "$indent" "$node"; return; fi; seen="$seen|$node|"; printf "%s%s\n" "$indent" "$node"; for c in ${_adj[$node]}; do _print_tree_recursive "$c" "  $indent" "$seen"; done; }
print_tree(){ _print_tree_recursive "$1" "" "|"; }

graphviz_dot(){
  echo "digraph deps { node [shape=box];"
  for n in "${!_nodes[@]}"; do
    local lbl="$n"; [ -n "${_reqver[$n]:-}" ] && lbl="$lbl\\n(${_reqver[$n]})"
    printf '  "%s" [label="%s"];\n' "$n" "$lbl"
  done
  for n in "${!_nodes[@]}"; do for c in ${_adj[$n]}; do printf '  "%s" -> "%s";\n' "$n" "$c"; done; done
  echo "}"
}

# ---------------- check version and possibly upgrade ----------------
# ensure_node_satisfied <node> <no_upgrade_flag>
ensure_node_satisfied(){
  local node="$1"; local no_upgrade="$2"
  local req="${_reqver[$node]:-}" inst
  if register_is_installed "$node"; then
    inst="$(get_installed_version "$node" 2>/dev/null || echo "")"
    if [ -n "$req" ]; then
      # parse req into op+ver
      if [[ "$req" =~ ^(>=|<=|=|>|<)(.+)$ ]]; then
        local op="${BASH_REMATCH[1]}" ver="${BASH_REMATCH[2]}"
        if version_satisfies "$inst" "$op" "$ver"; then
          log_info "Versão instalada de $node ($inst) satisfaz $op$ver"
          return 0
        else
          log_warn "Versão instalada de $node ($inst) NÃO satisfaz $op$ver"
          if [ "$no_upgrade" = "1" ]; then
            log_error "Não atualizar: política --no-upgrade ativa. Aborting."
            return 2
          fi
          # try upgrade
          if declare -F cmd_upgrade >/dev/null; then
            log_info "Tentando atualizar $node via cmd_upgrade..."
            cmd_upgrade "$node" || { log_error "cmd_upgrade falhou para $node"; return 1; }
            # re-read installed version
            inst="$(get_installed_version "$node" 2>/dev/null || echo "")"
            if version_satisfies "$inst" "$op" "$ver"; then
              log_info "Upgrade bem-sucedido: $node -> $inst"
              return 0
            else
              log_error "Após upgrade, $node ($inst) ainda não satisfaz $op$ver"
              return 1
            fi
          else
            log_error "cmd_upgrade não disponível; não é possível atualizar $node"
            return 1
          fi
        fi
      else
        # malformed req
        log_warn "Requisito de versão malformado para $node: $req"
        return 0
      fi
    else
      # no req version -> ok
      log_info "$node já instalado (versão $inst)"
      return 0
    fi
  else
    # not installed -> need to build/install
    log_info "$node não está instalado"
    return 100  # special code meaning 'install required'
  fi
}

# ---------------- resolve and install in topological order ----------------
resolve_and_install_deps(){
  local root="$1"; local dry="${2:-}"; local no_upgrade="${3:-}"
  build_graph "$root"
  _detect_cycle_dfs || return 1

  # produce topo order and reverse it so that dependencies come first
  local -a order; while IFS= read -r n; do order+=("$n"); done < <(topo_sort) || return 1
  local -a install_order; for ((i=${#order[@]}-1;i>=0;i--)); do install_order+=("${order[i]}"); done

  log_info "Ordem de instalação (dependencies first):"
  local idx node
  for idx in "${!install_order[@]}"; do node="${install_order[$idx]}"; printf "%3d. %s\n" "$((idx+1))" "$node"; done

  if [ "$dry" = "--dry-run" ]; then
    log_info "Dry-run: nenhuma ação será tomada."
    return 0
  fi

  for node in "${install_order[@]}"; do
    ensure_node_satisfied "$node" "$no_upgrade"
    local rc=$?
    if [ $rc -eq 0 ]; then
      log_info "OK: $node"
      continue
    elif [ $rc -eq 100 ]; then
      # needs install
      log_info "Instalando node $node ..."
      cmd_build "$node" || { log_error "Falha ao construir $node"; return 1; }
    else
      log_error "Erro verificando $node (code $rc)"
      return 1
    fi
  done
  return 0
}

# ---------------- CLI ----------------
cmd_deps(){
  local port="$1"; local action="${2:-topo}"; local flag3="$3"
  [ -n "$port" ] || { log_error "Uso: package deps <categoria/port> [tree|topo|graphviz|install|dry-run] [--no-upgrade]"; return 2; }
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

# export
export -f cmd_deps build_graph topo_sort graphviz_dot resolve_and_install_deps
