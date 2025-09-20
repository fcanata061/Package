#!/usr/bin/env bash
# dependency.advanced.sh - resolvedor de dependências por grafo e ordem topológica
# - Não usa gerenciadores binários do sistema
# - Resolve dependências a partir de metadados dos "ports" (Makefile vars ou arquivos deps)
# - Constrói grafo dirigido, detecta ciclos, faz ordenação topológica
# - Pode retornar ordem de build/instalação, executar build_port para cada dependência
# - Mantém um pequeno banco JSON (se python disponível) com status das builds

set -euo pipefail
IFS=$'\n\t'

PORTSDIR=${PORTSDIR:-/usr/ports}
DB_JSON=${DB_JSON:-/var/lib/package/dependencies.json}
LOG_DIR=${LOG_DIR:-/var/log/package}
CACHE_DIR=${CACHE_DIR:-/var/cache/package}

mkdir -p "$(dirname "$DB_JSON")" "$LOG_DIR" "$CACHE_DIR"

# logging
if ! declare -F log_info >/dev/null 2>&1; then
  log_info(){ echo "[dep][INFO] $*"; }
fi
if ! declare -F log_warn >/dev/null 2>&1; then
  log_warn(){ echo "[dep][WARN] $*"; }
fi
if ! declare -F log_error >/dev/null 2>&1; then
  log_error(){ echo "[dep][ERROR] $*" >&2; }
fi

# --- Utilitários ---
_portdir_from_name(){
  # aceita nome com barra (cat/port) ou com underscore cat_port ou caminho
  local name="$1"
  if [ -d "$name" ] && [ -f "$name/Makefile" ]; then
    printf '%s' "$name"; return 0
  fi
  if [[ "$name" == */* ]]; then
    local p="$PORTSDIR/$name"
    if [ -d "$p" ]; then printf '%s' "$p"; return 0; fi
  fi
  # underscore -> replace first '_' with '/'
  if [[ "$name" == *_* ]]; then
    local candidate="${name/_//}"
    if [ -d "$PORTSDIR/$candidate" ]; then printf '%s' "$PORTSDIR/$candidate"; return 0; fi
    # replace all '_' with '/'
    candidate="${name//_//}"
    if [ -d "$PORTSDIR/$candidate" ]; then printf '%s' "$PORTSDIR/$candidate"; return 0; fi
  fi
  # last resort: direct under PORTSDIR
  if [ -d "$PORTSDIR/$name" ]; then printf '%s' "$PORTSDIR/$name"; return 0; fi
  return 1
}

_makefile_read_var(){
  local mf="$1" var="$2"
  [ -f "$mf" ] || return 1
  awk -v v="$var" '
    $0 ~ "^[[:space:]]*"v"[[:space:]]*=" {
      sub("^[[:space:]]*"v"[[:space:]]*=" , "")
      val=$0
      while (val ~ /\\$/) { sub(/\\$/,"",val); if (getline nx) val=val nx; else break }
      sub(/#.*$/,"",val)
      gsub(/^[[:space:]]+/,"",val)
      gsub(/[[:space:]]+$/,"",val)
      print val; exit
    }
  ' "$mf" | xargs || true
}

# Parse dependencies from portdir
# procura variáveis: BUILD_DEPENDS, RUN_DEPENDS, TEST_DEPENDS, DEPENDS, and file portdir/deps
parse_deps_from_portdir(){
  local portdir="$1"
  local mf="$portdir/Makefile"
  local list=()
  if [ -f "$mf" ]; then
    for var in BUILD_DEPENDS RUN_DEPENDS TEST_DEPENDS DEPENDS; do
      local val
      val=$(_makefile_read_var "$mf" "$var") || val=""
      if [ -n "$val" ]; then
        # separar por espaços/commas
        # suporta formato: dep1 dep2 dep3 or dep1,dep2 or "cat/port"
        IFS=$' ,\t\n' read -r -a arr <<< "$val"
        for x in "${arr[@]}"; do
          [ -z "$x" ] && continue
          list+=("$x")
        done
      fi
    done
  fi
  if [ -f "$portdir/deps" ]; then
    while IFS= read -r line; do
      line="${line%%#*}"  # strip comments
      line="${line//[$'\t'  ]/ }"
      line="$(echo "$line" | xargs)"
      [ -z "$line" ] && continue
      list+=("$line")
    done < "$portdir/deps"
  fi
  # normalize names (strip paths like /usr/ports/..)
  local out=()
  for d in "${list[@]}"; do
    d="${d//\//\/}"
    out+=("$d")
  done
  printf '%s\n' "${out[@]}" | sed '/^$/d'
}

# Build graph from a set of root ports
# graph represented as associative arrays: neighbors and indeg
declare -A _G_NEIGHBORS  # key -> space-separated list of neighbors (dependencies)
declare -A _G_FOUND      # key -> 1

_graph_add_node(){ local n="$1"; _G_FOUND["$n"]=1; if [ -z "${_G_NEIGHBORS[$n]:-}" ]; then _G_NEIGHBORS[$n]=""; fi }
_graph_add_edge(){ local from="$1" to="$2"; _graph_add_node "$from"; _graph_add_node "$to"; local cur="${_G_NEIGHBORS[$from]}"; if [[ " $cur " != *" $to "* ]]; then _G_NEIGHBORS[$from]="${cur} $to"; fi }

# Recursively expand graph from roots (names as passed to parse/_portdir)
build_graph(){
  local roots=("$@")
  # clear
  _G_NEIGHBORS=()
  _G_FOUND=()
  local queue=()
  for r in "${roots[@]}"; do
    # normalize r to portdir form if possible
    if pdir=$(_portdir_from_name "$r"); then
      local key="${pdir#$PORTSDIR/}"
    else
      key="$r"
    fi
    queue+=("$key")
    _graph_add_node "$key"
  done

  while [ ${#queue[@]} -gt 0 ]; do
    local cur="${queue[0]}"; queue=("${queue[@]:1}")
    # if cur maps to a real portdir, parse deps
    if pdir=$(_portdir_from_name "$cur" 2>/dev/null || true); then
      local deps
      deps=$(parse_deps_from_portdir "$pdir" || true)
      if [ -n "$deps" ]; then
        while IFS= read -r d; do
          [ -z "$d" ] && continue
          # normalize dependent name to key
          if pd=$(_portdir_from_name "$d" 2>/dev/null || true); then
            local depkey="${pd#$PORTSDIR/}"
          else
            depkey="$d"
          fi
          _graph_add_edge "$cur" "$depkey"
          # enqueue if unseen
          if [ -z "${_G_FOUND[$depkey]:-}" ]; then
            queue+=("$depkey")
            _G_FOUND["$depkey"]=1
          fi
        done <<< "$deps"
      fi
    else
      # if no portdir, still create node
      :
    fi
  done
}

# Detect cycles using DFS
detect_cycles(){
  local visited=()
  declare -A state  # 0=unseen,1=visiting,2=done
  for n in "${!_G_NEIGHBORS[@]}"; do state["$n"]=0; done

  local cycle_found=0
  local stack=()
  _dfs(){
    local u="$1"
    state["$u"]=1
    stack+=("$u")
    local neighs="${_G_NEIGHBORS[$u]:-}"
    for v in $neighs; do
      if [ "${state[$v]:-0}" -eq 0 ]; then
        _dfs "$v" || return 1
      elif [ "${state[$v]}" -eq 1 ]; then
        # cycle
        cycle_found=1
        # print cycle path
        local path=()
        local i
        for i in "${!stack[@]}"; do
          path+=("${stack[$i]}")
        done
        path+=("$v")
        log_error "Ciclo detectado: ${path[*]}"
        return 1
      fi
    done
    # pop
    stack=("${stack[@]:0:${#stack[@]}-1}")
    state["$u"]=2
    return 0
  }

  for n in "${!_G_NEIGHBORS[@]}"; do
    if [ "${state[$n]}" -eq 0 ]; then
      _dfs "$n" || return 1
    fi
  done
  return 0
}

# Topological sort (Kahn's algorithm)
topological_sort(){
  # compute indegrees
  declare -A indeg
  for n in "${!_G_NEIGHBORS[@]}"; do indeg["$n"]=0; done
  for n in "${!_G_NEIGHBORS[@]}"; do
    for v in ${_G_NEIGHBORS[$n]}; do
      indeg["$v"]=$(( ${indeg["$v"]:-0} + 1 ))
    done
  done
  # queue nodes with indeg 0
  local q=()
  for n in "${!_G_NEIGHBORS[@]}"; do
    if [ ${indeg["$n"]:-0} -eq 0 ]; then q+=("$n"); fi
  done
  local order=()
  while [ ${#q[@]} -gt 0 ]; do
    local u="${q[0]}"; q=("${q[@]:1}")
    order+=("$u")
    for v in ${_G_NEIGHBORS[$u]}; do
      indeg["$v"]=$(( ${indeg["$v"]} - 1 ))
      if [ ${indeg["$v"]} -eq 0 ]; then q+=("$v"); fi
    done
  done
  # if order size != nodes size -> cycle
  local total=0
  for n in "${!_G_NEIGHBORS[@]}"; do total=$((total+1)); done
  if [ ${#order[@]} -ne $total ]; then
    log_error "topological_sort: grafo tem ciclo ou nós isolados"
    return 1
  fi
  # print order, one per line
  for x in "${order[@]}"; do printf '%s\n' "$x"; done
}

# get_build_order roots... -> prints in build order (dependencies first)
get_build_order(){
  build_graph "$@"
  detect_cycles || return 1
  topological_sort
}

# persistent DB helpers (JSON if python available)
_db_write(){
  local key="$1" status="$2" stamp
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<PY -c "$key $status"
import json,sys
DB='''$(cat <<'EOF'
$(cat "$DB_JSON" 2>/dev/null || echo '{}')
EOF
)'''
try:
    d=json.loads(DB)
except Exception:
    d={}
try:
    d['$key']={'status':'$status','updated':'$stamp'}
except Exception:
    pass
print(json.dumps(d,indent=2))
PY
  else
    # fallback: append simple TSV
    echo -e "$key\t$status\t$stamp" >> "$DB_JSON".log
  fi
}

# Build dependencies and optionally execute build_port for each in order
# Usage: build_with_deps ROOT_PORT [--no-build] [--parallel N]
build_with_deps(){
  local root="$1"; shift
  local do_build=yes
  local parallel=1
  while [ $# -gt 0 ]; do case "$1" in --no-build) do_build=no; shift;; --parallel) parallel="$2"; shift 2;; *) shift;; esac; done

  local order
  mapfile -t order < <(get_build_order "$root") || { log_error "Não foi possível obter build order"; return 1; }
  log_info "Ordem de build (dependências primeiro): ${order[*]}"

  # If do_build=no, just print order
  if [ "$do_build" = "no" ]; then
    for p in "${order[@]}"; do echo "$p"; done
    return 0
  fi

  # build sequentially by default
  for p in "${order[@]}"; do
    # if already built (simple heuristic: files list exists)
    if [ -f "$FILES_DIR/${p}.list" ]; then
      log_info "Pulando $p — já construído (files list presente)"
      continue
    fi
    # try to find portdir
    if pdir=$(_portdir_from_name "$p" 2>/dev/null || true); then
      log_info "Construindo dependência $p -> $pdir"
      # call build_port if available
      if declare -F build_port >/dev/null 2>&1; then
        build_port "$pdir" || { log_error "build_port falhou para $p"; return 1; }
        _db_write "$p" "built"
      else
        log_warn "build_port não disponível; apenas listando $p"
      fi
    else
      log_warn "Diretório do port não encontrado para $p; pulando"
    fi
  done
}

export -f parse_deps_from_portdir build_graph detect_cycles topological_sort get_build_order build_with_deps
