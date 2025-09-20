#!/usr/bin/env bash
# dependency.parallel.jsonl.sh (v2)
# Resolvedor de dependências com:
#  - detecção de grafo e ordenação topológica
#  - execução paralela segura
#  - retries automáticos por worker com backoff
#  - persistência JSONL + compactação em JSON com histórico
#  - verificação de recursos (memória disponível e load avg) antes de agendar workers
#
# Uso:
#   source dependency.parallel.jsonl.sh
#   build_with_deps_parallel category/port --parallel 4 --retries 2
#
# Requisitos:
#   - bash moderno (wait -n)
#   - build_port (opcional) para executar builds reais
#
set -euo pipefail
IFS=$'\n\t'

# ---------------- Configuráveis ----------------
PORTSDIR=${PORTSDIR:-/usr/ports}
DB_JSONL=${DB_JSONL:-/var/lib/package/dependencies.jsonl}
DB_JSON=${DB_JSON:-/var/lib/package/dependencies.json}
LOG_DIR=${LOG_DIR:-/var/log/package}
FILES_DIR=${FILES_DIR:-/var/lib/package/files}
CACHE_DIR=${CACHE_DIR:-/var/cache/package}
TMPDIR=${TMPDIR:-/var/tmp/package-dep}
MIN_FREE_MEM_MB=${MIN_FREE_MEM_MB:-256}    # mínimo de memória livre MB requerido por worker
MAX_LOAD_PER_CPU=${MAX_LOAD_PER_CPU:-1.5}  # carga 1min por CPU limite
DEFAULT_PARALLEL=${DEFAULT_PARALLEL:-4}
RETRY_COUNT_DEFAULT=${RETRY_COUNT_DEFAULT:-2}
RETRY_BACKOFF_BASE=${RETRY_BACKOFF_BASE:-2} # segundos (exponencial)

mkdir -p "$(dirname "$DB_JSONL")" "$(dirname "$DB_JSON")" "$LOG_DIR" "$CACHE_DIR" "$TMPDIR" "$FILES_DIR"

# --------- Logging mínimos ----------
if ! declare -F log_info >/dev/null 2>&1; then
  log_info(){ echo "[dep][INFO] $*"; }
fi
if ! declare -F log_warn >/dev/null 2>&1; then
  log_warn(){ echo "[dep][WARN] $*"; }
fi
if ! declare -F log_error >/dev/null 2>&1; then
  log_error(){ echo "[dep][ERROR] $*" >&2; }
fi

# ------------------ Utils para mapear ports ------------------
_portdir_from_name(){
  local name="$1"
  if [ -d "$name" ] && [ -f "$name/Makefile" ]; then
    printf '%s' "$name"; return 0
  fi
  if [[ "$name" == */* ]]; then
    local p="$PORTSDIR/$name"
    [ -d "$p" ] && printf '%s' "$p" && return 0
  fi
  if [[ "$name" == *_* ]]; then
    local cand1="${name/_//}"
    [ -d "$PORTSDIR/$cand1" ] && printf '%s' "$PORTSDIR/$cand1" && return 0
    local cand2="${name//_//}"
    [ -d "$PORTSDIR/$cand2" ] && printf '%s' "$PORTSDIR/$cand2" && return 0
  fi
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

parse_deps_from_portdir(){
  local portdir="$1"
  local mf="$portdir/Makefile"
  local list=()
  if [ -f "$mf" ]; then
    for var in BUILD_DEPENDS RUN_DEPENDS TEST_DEPENDS DEPENDS; do
      local val
      val=$(_makefile_read_var "$mf" "$var") || val=""
      if [ -n "$val" ]; then
        IFS=$' ,\t\n' read -r -a arr <<< "$val"
        for x in "${arr[@]}"; do [ -z "$x" ] && continue; list+=("$x"); done
      fi
    done
  fi
  if [ -f "$portdir/deps" ]; then
    while IFS= read -r line; do
      line="${line%%#*}"; line="$(echo "$line" | xargs)"; [ -z "$line" ] && continue
      list+=("$line")
    done < "$portdir/deps"
  fi
  for d in "${list[@]}"; do printf '%s\n' "$d"; done
}

# ------------------ Grafo ------------------
declare -A G_NEI   # node -> neighbors (deps)
declare -A G_NODES # set of nodes

_graph_add_node(){ local n="$1"; G_NODES["$n"]=1; if [ -z "${G_NEI[$n]:-}" ]; then G_NEI[$n]=""; fi }
_graph_add_edge(){ local a="$1" b="$2"; _graph_add_node "$a"; _graph_add_node "$b"; local cur="${G_NEI[$a]}"; if [[ " $cur " != *" $b "* ]]; then G_NEI[$a]="${cur} $b"; fi }

build_graph(){
  local roots=( "$@" )
  G_NEI=()
  G_NODES=()
  local queue=()
  for r in "${roots[@]}"; do
    if pdir=$(_portdir_from_name "$r" 2>/dev/null || true); then key="${pdir#$PORTSDIR/}"; else key="$r"; fi
    queue+=("$key"); _graph_add_node "$key"
  done
  while [ ${#queue[@]} -gt 0 ]; do
    cur="${queue[0]}"; queue=( "${queue[@]:1}" )
    if pdir=$(_portdir_from_name "$cur" 2>/dev/null || true); then
      deps=$(parse_deps_from_portdir "$pdir" || true)
      if [ -n "$deps" ]; then
        while IFS= read -r d; do [ -z "$d" ] && continue
          if pd=$(_portdir_from_name "$d" 2>/dev/null || true); then depkey="${pd#$PORTSDIR/}"; else depkey="$d"; fi
          _graph_add_edge "$cur" "$depkey"
          if [ -z "${G_NODES[$depkey]:-}" ]; then queue+=("$depkey"); G_NODES[$depkey]=1; fi
        done <<< "$deps"
      fi
    fi
  done
}

# ------------------ Ciclos ------------------
detect_cycles(){
  declare -A state
  for n in "${!G_NEI[@]}"; do state[$n]=0; done
  local stack=()
  local found=0
  _dfs(){
    local u="$1"
    state[$u]=1
    stack+=( "$u" )
    for v in ${G_NEI[$u]}; do
      if [ "${state[$v]:-0}" -eq 0 ]; then
        _dfs "$v" || return 1
      elif [ "${state[$v]}" -eq 1 ]; then
        found=1
        log_error "Ciclo detectado: ${stack[*]} $v"
        return 1
      fi
    done
    stack=( "${stack[@]:0:${#stack[@]}-1}" )
    state[$u]=2
    return 0
  }
  for n in "${!G_NEI[@]}"; do
    if [ "${state[$n]}" -eq 0 ]; then _dfs "$n" || return 1; fi
  done
  return 0
}

# ------------------ Ordenação topológica (Kahn) ------------------
topological_sort(){
  declare -A indeg
  for n in "${!G_NEI[@]}"; do indeg[$n]=0; done
  for n in "${!G_NEI[@]}"; do
    for v in ${G_NEI[$n]}; do indeg[$v]=$(( ${indeg[$v]:-0} + 1 )); done
  done
  local q=()
  for n in "${!G_NEI[@]}"; do if [ ${indeg[$n]:-0} -eq 0 ]; then q+=( "$n" ); fi; done
  local order=()
  while [ ${#q[@]} -gt 0 ]; do
    u="${q[0]}"; q=( "${q[@]:1}" )
    order+=( "$u" )
    for v in ${G_NEI[$u]}; do
      indeg[$v]=$(( ${indeg[$v]} - 1 ))
      if [ ${indeg[$v]} -eq 0 ]; then q+=( "$v" ); fi
    done
  done
  total=0; for n in "${!G_NEI[@]}"; do total=$((total+1)); done
  if [ ${#order[@]} -ne $total ]; then log_error "topological_sort: ciclo ou nó isolado"; return 1; fi
  for x in "${order[@]}"; do printf '%s\n' "$x"; done
}

# ------------------ DB JSONL helpers (append-only) ------------------
_db_append(){
  local key="$1" status="$2" stamp
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"port":"%s","status":"%s","updated":"%s"}\n' "${key//\"/\\\"}" "${status//\"/\\\"}" "$stamp" >> "$DB_JSONL"
}

# ------------------ DB Compact: gera JSON com histórico ------------------
# Formato final (DB_JSON): {
#   "port1": {"last": {"status":"built","updated":"..."}, "history":[ {"status":"...","updated":"..."}, ... ]},
#   ...
# }
_db_compact(){
  # backup previous json
  if [ -f "$DB_JSON" ]; then
    cp -a "$DB_JSON" "${DB_JSON}.bak.$(date +%Y%m%d%H%M%S)" || true
  fi
  # temporary map: create a temp file per port with history lines (status|updated)
  rm -rf "$TMPDIR/db_parts.$$" || true
  mkdir -p "$TMPDIR/db_parts.$$"
  while IFS= read -r line; do
    # parse port,status,updated
    port=$(printf "%s" "$line" | sed -n 's/.*"port":"\([^"]*\)".*/\1/p')
    status=$(printf "%s" "$line" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')
    updated=$(printf "%s" "$line" | sed -n 's/.*"updated":"\([^"]*\)".*/\1/p')
    [ -z "$port" ] && continue
    echo -e "${status}\t${updated}" >> "$TMPDIR/db_parts.$$/$(echo "$port" | sed 's/[^A-Za-z0-9._-]/_/g')"
  done < "$DB_JSONL"
  # build JSON
  out="$TMPDIR/db_compact.$$"
  echo "{" > "$out"
  first_port=1
  for f in "$TMPDIR/db_parts.$$/"*; do
    [ -f "$f" ] || continue
    portname=$(basename "$f")
    # restore original port name (we replaced unsafe chars with _; keep that)
    # read all lines and build history array
    history_json=""
    last_status=""
    last_updated=""
    while IFS=$'\t' read -r st up; do
      # escape
      st_e=$(printf '%s' "$st" | sed 's/"/\\"/g')
      up_e=$(printf '%s' "$up" | sed 's/"/\\"/g')
      if [ -z "$history_json" ]; then
        history_json="[{\"status\":\"$st_e\",\"updated\":\"$up_e\"}]"
      else
        history_json="${history_json%,}]},"
        # simpler: build by appending
        history_json=$(printf '%s' "$history_json" | sed 's/]$/,/')
        history_json="${history_json%?}"
      fi
      # but simpler: append to temp array file and later read
      echo "{\"status\":\"$st_e\",\"updated\":\"$up_e\"}" >> "$f.history"
      last_status="$st_e"
      last_updated="$up_e"
    done < "$f"
    # build history by reading file
    hist_items=""
    if [ -f "$f.history" ]; then
      while IFS= read -r l; do
        if [ -z "$hist_items" ]; then hist_items="$l"; else hist_items="$hist_items,$l"; fi
      done < "$f.history"
      rm -f "$f.history"
    fi
    if [ -z "$hist_items" ]; then hist_items="[]"; else hist_items="[$hist_items]"; fi
    if [ $first_port -eq 1 ]; then first_port=0; else echo "," >> "$out"; fi
    printf '  "%s": { "last": {"status":"%s","updated":"%s"}, "history": %s }\n' \
      "$portname" "${last_status:-unknown}" "${last_updated:-}" "$hist_items" >> "$out"
  done
  echo "}" >> "$out"
  mv "$out" "$DB_JSON"
  rm -rf "$TMPDIR/db_parts.$$" || true
}

# ------------------ Recursos ------------------
# retorna memória livre em MB (approx: MemAvailable or MemFree)
_get_free_mem_mb(){
  if [ -r /proc/meminfo ]; then
    # prefer MemAvailable
    local m=$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo)
    if [ -n "$m" ]; then
      # value in kB -> MB
      echo $((m/1024))
      return 0
    fi
    m=$(awk '/^MemFree:/ {print $2; exit}' /proc/meminfo)
    if [ -n "$m" ]; then echo $((m/1024)); return 0; fi
  fi
  # fallback: 0
  echo 0
}

# retorna loadavg 1min
_get_loadavg_1min(){
  awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0
}

# checa se recursos permitem agendar mais workers
# args: running current_running desired_additional_workers
_resources_ok_for_workers(){
  local running="$1"; shift
  local add="$1"
  local total_workers=$((running + add))
  local nproc=$(nproc 2>/dev/null || echo 1)
  local free_mb=$(_get_free_mem_mb)
  local needed_mb=$(( MIN_FREE_MEM_MB * total_workers ))
  local load1=$(_get_loadavg_1min)
  # compare load per cpu
  # using bc isn't allowed; do float compare via awk
  local max_total_load
  max_total_load=$(awk -v m="$MAX_LOAD_PER_CPU" -v p="$nproc" 'BEGIN{printf "%.6f", m * p}')
  local ok_mem=0 ok_load=0
  if [ "$free_mb" -ge "$needed_mb" ]; then ok_mem=1; fi
  # compare load1 <= max_total_load
  local cmp=$(awk -v a="$load1" -v b="$max_total_load" 'BEGIN{print (a<=b)?1:0}')
  if [ "$cmp" -eq 1 ]; then ok_load=1; fi
  if [ $ok_mem -eq 1 ] && [ $ok_load -eq 1 ]; then
    return 0
  fi
  log_warn "Recursos insuficientes: free_mb=${free_mb}MB needed=${needed_mb}MB load1=${load1} max_allowed=${max_total_load}"
  return 1
}

# ------------------ Worker com retries e backoff ------------------
# build_worker node retry_count -> exit code 0 success, nonzero failure
_build_worker_internal(){
  local node="$1"; local retries="$2"
  local attempt=0
  while true; do
    attempt=$((attempt+1))
    log_info "Worker: construindo $node (tentativa $attempt/$((retries+1)))"
    # já construído?
    if [ -f "$FILES_DIR/${node}.list" ]; then
      log_info "Worker: $node já construído (files list presente)."
      return 0
    fi
    if pdir=$(_portdir_from_name "$node" 2>/dev/null || true); then
      if declare -F build_port >/dev/null 2>&1; then
        if build_port "$pdir"; then
          log_info "Worker: $node build OK"
          return 0
        else
          log_warn "Worker: build_port retornou erro para $node"
        fi
      else
        log_warn "build_port ausente; simulando build OK para $node"
        return 0
      fi
    else
      log_warn "Portdir não encontrado para $node; marcando como feito"
      return 0
    fi
    if [ $attempt -le "$retries" ]; then
      # backoff
      sleep_seconds=$(( RETRY_BACKOFF_BASE ** (attempt-1) ))
      log_info "Worker: $node vai tentar novamente em ${sleep_seconds}s"
      sleep "$sleep_seconds"
      continue
    fi
    log_error "Worker: $node falhou após $attempt tentativas"
    return 2
  done
}

# spawn wrapper to call internal worker and exit with its code
_build_worker_spawn(){
  local node="$1"; local retries="$2"
  _build_worker_internal "$node" "$retries"
  exit $?
}

# ------------------ Scheduler paralelo com verificação de recursos ------------------
build_with_deps_parallel(){
  local root="$1"; shift
  local parallel="$DEFAULT_PARALLEL"
  local do_build=yes
  local retries="$RETRY_COUNT_DEFAULT"
  while [ $# -gt 0 ]; do
    case "$1" in
      --parallel) parallel="$2"; shift 2;;
      --no-build) do_build=no; shift;;
      --retries) retries="$2"; shift 2;;
      *) shift;;
    esac
  done

  build_graph "$root"
  detect_cycles || return 1

  # indeg and reverse adjacency
  declare -A indeg rev
  for n in "${!G_NEI[@]}"; do indeg[$n]=0; done
  for n in "${!G_NEI[@]}"; do for v in ${G_NEI[$n]}; do indeg[$v]=$(( ${indeg[$v]:-0} + 1 )); rev[$v]="${rev[$v]} $n"; done; done

  # ready queue
  local ready=()
  for n in "${!G_NEI[@]}"; do if [ ${indeg[$n]:-0} -eq 0 ]; then ready+=( "$n" ); fi; done

  declare -A PID2NODE
  declare -A NODE_STATUS  # pending|running|done|failed

  local running=0

  # main loop
  while true; do
    # schedule while capacity and ready nodes available, and resources OK
    while [ $running -lt "$parallel" ] && [ ${#ready[@]} -gt 0 ]; do
      # check resources if scheduling one more
      if ! _resources_ok_for_workers "$running" 1; then
        log_info "Aguardar recursos para agendar mais workers..."
        break
      fi
      node="${ready[0]}"; ready=( "${ready[@]:1}" )
      NODE_STATUS[$node]=queued
      if [ "$do_build" = "no" ]; then
        log_info "Simulação: agendado (no-build) $node"
        # mark as done without actually building
        NODE_STATUS[$node]=done
        _db_append "$node" "simulated"
        for neigh in ${G_NEI[$node]}; do
          indeg[$neigh]=$(( indeg[$neigh] - 1 ))
          if [ ${indeg[$neigh]} -eq 0 ]; then ready+=( "$neigh" ); fi
        done
        continue
      fi
      # spawn worker in background
      (
        _build_worker_internal "$node" "$retries"
      ) &
      pid=$!
      PID2NODE[$pid]="$node"
      running=$((running+1))
      NODE_STATUS[$node]=running
      log_info "Scheduled $node (pid=$pid). running=$running"
    done

    # exit condition: no running and no ready nodes
    if [ $running -eq 0 ] && [ ${#ready[@]} -eq 0 ]; then
      break
    fi

    # wait for any job to finish
    if ! wait -n 2>/dev/null; then
      rc=$?
    else
      rc=$?
    fi

    # find finished pid(s) by checking PID2NODE map for dead pids
    finished_pid=""
    for p in "${!PID2NODE[@]}"; do
      if ! kill -0 "$p" 2>/dev/null; then finished_pid="$p"; break; fi
    done
    if [ -z "$finished_pid" ]; then
      # small sleep to avoid busy loop
      sleep 0.2
      continue
    fi
    # reap
    wait "$finished_pid" || rc=$?
    node="${PID2NODE[$finished_pid]}"
    unset PID2NODE[$finished_pid]
    running=$((running-1))
    if [ ${rc:-0} -eq 0 ]; then
      NODE_STATUS[$node]=done
      _db_append "$node" "built"
      log_info "Node $node concluído com sucesso. rc=$rc"
      # decrease indeg of neighbors
      for neigh in ${G_NEI[$node]}; do
        indeg[$neigh]=$(( indeg[$neigh] - 1 ))
        if [ ${indeg[$neigh]} -eq 0 ]; then ready+=( "$neigh" ); fi
      done
    else
      NODE_STATUS[$node]=failed
      _db_append "$node" "failed"
      log_error "Node $node falhou (rc=$rc). Abortando scheduler."
      _db_compact || true
      return 1
    fi
  done

  # compact DB
  _db_compact || true
  log_info "build_with_deps_parallel concluído com sucesso"
  return 0
}

# ------------------ Aux: get build order (dependencies first) ------------------
get_build_order(){
  build_graph "$@"
  detect_cycles || return 1
  topological_sort
}

# Export functions
export -f build_graph detect_cycles topological_sort get_build_order build_with_deps_parallel

# If invoked directly, show usage
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "Uso: source $0  # então chame build_with_deps_parallel <root> [--parallel N] [--retries R] [--no-build]"
  exit 0
fi
