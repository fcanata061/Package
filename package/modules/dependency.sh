#!/usr/bin/env bash
# modules/dependency.sh
# Gerenciamento de dependências completo e funcional
# Suporta BUILD_DEPENDS, RUN_DEPENDS e DEPENDS; versão, ciclos, topo, paralelo, dry-run.
#
# Exporta:
#   cmd_deps <categoria/port> [tree|topo|graphviz|install|dry-run] [--no-upgrade]
#   resolve_and_install_deps <categoria/port> [--dry-run] [--no-upgrade]
#   build_graph <categoria/port>
#   topo_sort
#   graphviz_dot
#
# Espera (funções externas, com fallbacks):
#   register_is_installed <categoria/port>
#   get_installed_version <categoria/port>
#   cmd_build <categoria/port>
#   cmd_upgrade <categoria/port>   (opcional — usado se houver versão incompatível)
#   log_info/log_warn/log_error
#
# Variáveis:
#   PORTSDIR (padrão /usr/ports)
#   DEP_LOG_DIR (padrão /var/log/package/deps)
#   PARALLEL_JOBS (padrão 1)

PORTSDIR=${PORTSDIR:-/usr/ports}
DEP_LOG_DIR=${DEP_LOG_DIR:-/var/log/package/deps}
PARALLEL_JOBS=${PARALLEL_JOBS:-1}
mkdir -p "$DEP_LOG_DIR"

# ---------- logging fallbacks ----------
: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_error:=:}"

if ! declare -F log_info >/dev/null; then
  log_info(){ echo "[deps][INFO] $*"; }
fi
if ! declare -F log_warn >/dev/null; then
  log_warn(){ echo "[deps][WARN] $*"; }
fi
if ! declare -F log_error >/dev/null; then
  log_error(){ echo "[deps][ERROR] $*" >&2; }
fi

# ---------- fallbacks para integração ----------
if ! declare -F register_is_installed >/dev/null; then
  register_is_installed(){ return 1; }  # assume não instalado
fi

if ! declare -F get_installed_version >/dev/null; then
  # tenta ler /var/lib/package/installed/<category>_<port> com VERSION=
  get_installed_version(){
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

# cmd_upgrade opcional — se ausente, tentativas de upgrade falharão com mensagem
if ! declare -F cmd_upgrade >/dev/null; then
  cmd_upgrade(){ log_error "cmd_upgrade não disponível"; return 2; }
fi

# ---------- utilitários de versão ----------
_vnorm(){ printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

# v1 >= v2 ? -> retorna 0 se true
version_ge(){
  local v1=$(_vnorm "$1"); local v2=$(_vnorm "$2")
  [ -z "$v2" ] && return 0
  [ -z "$v1" ] && return 1
  [ "$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | head -n1)" = "$v2" ]
}

version_eq(){ [ "$(_vnorm "$1")" = "$(_vnorm "$2")" ]; }

# instalado satisfaz op + req ?
version_satisfies(){
  local inst="$(_vnorm "$1")" op="$2" req="$(_vnorm "$3")"
  [ -z "$op" ] && return 0
  case "$op" in
    ">=") version_ge "$inst" "$req" ;;
    "<=") version_ge "$req" "$inst" ;;
    "=")  version_eq "$inst" "$req" ;;
    ">")  version_ge "$inst" "$req" && ! version_eq "$inst" "$req" ;;
    "<")  version_ge "$req" "$inst" && ! version_eq "$inst" "$req" ;;
    *) return 1 ;;
  esac
}

# ---------- parse Makefile variables (supports continuations) ----------
_makefile_var(){
  local port="$1" var="$2"
  local mf="$PORTSDIR/$port/Makefile"
  [ -f "$mf" ] || return 1
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
    }' "$mf" | sed 's/#.*//' | xargs
}

# tokeniza lista de dependências (preserva tokens separados por espaço)
_tokenize_deps(){ local s="$*"; for t in $s; do echo "$t"; done; }

# parse token: 'cat/pkg>=1.2' -> name op ver
_parse_dep_token(){
  local tok="$1"
  if [[ "$tok" =~ ^([^><=]+)(>=|<=|=|>|<)(.+)$ ]]; then
    printf '%s\t%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
  else
    printf '%s\t%s\t%s\n' "$tok" "" ""
  fi
}

# ---------- map token sem categoria para categoria/port ----------
# Se token já tem '/', retorna como está. Caso contrário, tenta procurar no PORTSDIR pelo nome.
resolve_port_name(){
  local token="$1"
  if [[ "$token" == */* ]]; then
    printf '%s' "$token"
    return 0
  fi

  # procura por diretório cujo nome é token em /usr/ports/*/token
  local matches
  IFS=$'\n' read -r -d '' -a matches < <(find "$PORTSDIR" -mindepth 2 -maxdepth 2 -type d -name "$token" -print0 2>/dev/null | tr '\0' '\n' ; printf '\0')
  # find above with print0 then converting; simpler: do a for
  # fallback simple search:
  matches=()
  while IFS= read -r -d '' d; do matches+=("$d"); done < <(find "$PORTSDIR" -mindepth 2 -maxdepth 2 -type d -name "$token" -print0 2>/dev/null)

  if [ "${#matches[@]}" -eq 0 ]; then
    log_warn "Não encontrei port $token em $PORTSDIR; assumindo token como foi passado"
    printf '%s' "$token"
    return 0
  elif [ "${#matches[@]}" -gt 1 ]; then
    log_warn "Múltiplos ports correspondem a '$token'. Usando o primeiro: ${matches[0]}"
  fi

  local rel="${matches[0]#"$PORTSDIR/"}"
  printf '%s' "$rel"
}

# ---------- grafo (associative arrays) ----------
declare -A _adj _indeg _nodes _reqver
_graph_reset(){
  _adj=(); _indeg=(); _nodes=(); _reqver=();
}

_graph_add_node(){
  local n="$1"
  _nodes["$n"]=1
  [ -n "${_adj[$n]:-}" ] || _adj["$n"]=""
  [ -n "${_indeg[$n]:-}" ] || _indeg["$n"]=0
}

_graph_add_edge(){
  local from="$1" to="$2"
  _graph_add_node "$from"; _graph_add_node "$to"
  if [[ " ${_adj[$from]} " != *" $to "* ]]; then
    _adj["$from"]="${_adj[$from]} $to"
    _indeg["$to"]=$(( ${_indeg["$to"]} + 1 ))
  fi
}

# ---------- construir grafo recursivamente ----------
_build_graph_recursive(){
  local port="$1"
  local seen="$2"
  if [[ "$seen" == *"|$port|"* ]]; then return 0; fi
  seen="$seen|$port|"
  _graph_add_node "$port"

  # fallback compatibilidade: DEPENDS -> both build+run
  local bstr rstr dstr token nm op ver resolved
  dstr=$(_makefile_var "$port" "DEPENDS" 2>/dev/null || true)
  bstr=$(_makefile_var "$port" "BUILD_DEPENDS" 2>/dev/null || true)
  rstr=$(_makefile_var "$port" "RUN_DEPENDS" 2>/dev/null || true)

  # merge: explicit BUILD_DEPENDS and RUN_DEPENDS take precedence; DEPENDS only used if others empty
  if [ -z "$bstr" ] && [ -n "$dstr" ]; then bstr="$dstr"; fi
  if [ -z "$rstr" ] && [ -n "$dstr" ]; then rstr="$dstr"; fi

  for token in $(_tokenize_deps $bstr); do
    IFS=$'\t' read -r nm op ver < <(_parse_dep_token "$token")
    resolved=$(resolve_port_name "$nm")
    [ -n "$op" ] && [ -n "$ver" ] && [ -z "${_reqver[$resolved]:-}" ] && _reqver["$resolved"]="${op}${ver}"
    _graph_add_edge "$port" "$resolved"
    _build_graph_recursive "$resolved" "$seen"
  done

  for token in $(_tokenize_deps $rstr); do
    IFS=$'\t' read -r nm op ver < <(_parse_dep_token "$token")
    resolved=$(resolve_port_name "$nm")
    [ -n "$op" ] && [ -n "$ver" ] && [ -z "${_reqver[$resolved]:-}" ] && _reqver["$resolved"]="${op}${ver}"
    _graph_add_edge "$port" "$resolved"
    _build_graph_recursive "$resolved" "$seen"
  done
}

build_graph(){ local root="$1"; _graph_reset; _build_graph_recursive "$root" "|"; }

# ---------- detectar ciclos (DFS) ----------
_detect_cycle_dfs(){
  local _cycle_found=0 _cycle_path=""
  declare -Ag _visited; for n in "${!_nodes[@]}"; do unset _visited["$n"]; done

  _dfs_visit(){
    local node="$1" stack="$2"
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
        log_error "Ciclo de dependência detectado: $out"
        return 1
      fi
    fi
  done
  return 0
}

# ---------- ordenação topológica (Kahn) ----------
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

  # se ainda existe indegree >0 -> ciclo
  for n in "${!_nodes[@]}"; do
    if [ "${indeg_copy[$n]:-0}" -gt 0 ]; then
      log_error "topo_sort: ciclo detectado"
      return 1
    fi
  done

  for n in "${order[@]}"; do printf '%s\n' "$n"; done
}

# ---------- print tree ----------
_print_tree_recursive(){
  local node="$1" indent="$2" seen="$3"
  if [[ "$seen" == *"|$node|"* ]]; then
    printf "%s%s (seen)\n" "$indent" "$node"
    return
  fi
  seen="$seen|$node|"
  printf "%s%s\n" "$indent" "$node"
  for c in ${_adj[$node]}; do
    _print_tree_recursive "$c" "  $indent" "$seen"
  done
}
print_tree(){ _print_tree_recursive "$1" "" "|"; }

# ---------- graphviz DOT ----------
graphviz_dot(){
  echo "digraph deps { node [shape=box];"
  for n in "${!_nodes[@]}"; do
    local lbl="$n"
    [ -n "${_reqver[$n]:-}" ] && lbl="$lbl\\n(${_reqver[$n]})"
    printf '  "%s" [label="%s"];\n' "$n" "$lbl"
  done
  for n in "${!_nodes[@]}"; do
    for c in ${_adj[$n]}; do
      printf '  "%s" -> "%s";\n' "$n" "$c"
    done
  done
  echo "}"
}

# ---------- garantir que node satisfeito (instalado/versão) ----------
# retorna:
#   0 -> ok (instalado e satisfaz requisito ou sem requisito)
#   100 -> precisa instalar
#   1..n -> erro
ensure_node_satisfied(){
  local node="$1" no_upgrade="$2"
  local req="${_reqver[$node]:-}" inst

  if register_is_installed "$node"; then
    inst="$(get_installed_version "$node" 2>/dev/null || echo "")"
    if [ -n "$req" ]; then
      if [[ "$req" =~ ^(>=|<=|=|>|<)(.+)$ ]]; then
        local op="${BASH_REMATCH[1]}" ver="${BASH_REMATCH[2]}"
        if version_satisfies "$inst" "$op" "$ver"; then
          log_info "Versão instalada de $node ($inst) satisfaz $op$ver"
          return 0
        else
          log_warn "Versão instalada de $node ($inst) NÃO satisfaz $op$ver"
          if [ "$no_upgrade" = "1" ]; then
            log_error "Política --no-upgrade ativa; abortando para $node"
            return 2
          fi
          if declare -F cmd_upgrade >/dev/null; then
            log_info "Tentando atualizar $node via cmd_upgrade..."
            cmd_upgrade "$node" || { log_error "cmd_upgrade falhou para $node"; return 1; }
            inst="$(get_installed_version "$node" 2>/dev/null || echo "")"
            if version_satisfies "$inst" "$op" "$ver"; then
              log_info "Upgrade bem-sucedido: $node -> $inst"
              return 0
            else
              log_error "Após upgrade, $node ($inst) ainda não satisfaz $op$ver"
              return 1
            fi
          else
            log_error "cmd_upgrade não disponível; impossível atualizar $node"
            return 1
          fi
        fi
      else
        log_warn "Requisito de versão malformado para $node: $req"
        return 0
      fi
    else
      log_info "$node já instalado (versão $inst)"
      return 0
    fi
  else
    log_info "$node não está instalado"
    return 100
  fi
}

# ---------- resolve and install deps (topo order, reverse) ----------
resolve_and_install_deps(){
  local root="$1"; local dry="${2:-}"; local no_upgrade="${3:-}"
  build_graph "$root"
  _detect_cycle_dfs || return 1

  # topo_sort produces an order where nodes with zero out-degree first (depends on edge direction)
  local -a order
  while IFS= read -r n; do order+=("$n"); done < <(topo_sort) || return 1

  # reverse so dependencies are installed before dependents
  local -a install_order
  for ((i=${#order[@]}-1;i>=0;i--)); do install_order+=("${order[i]}"); done

  log_info "Ordem de instalação (dependencies first):"
  local idx node
  for idx in "${!install_order[@]}"; do
    node="${install_order[$idx]}"
    printf "%3d. %s\n" "$((idx+1))" "$node"
  done

  if [ "$dry" = "--dry-run" ]; then
    log_info "Dry-run: nenhuma ação será tomada."
    return 0
  fi

  # se PARALLEL_JOBS > 1, instalamos por "níveis" (nodes com mesmas dependências podem rodar em paralelo)
  # calcular níveis simples: repetidamente pegar nodes com indegree 0 (na subgrafo remanescente)
  local -a remaining
  remaining=("${install_order[@]}")

  while [ "${#remaining[@]}" -gt 0 ]; do
    # build map indegree for remaining set
    declare -A indeg_now
    for n in "${remaining[@]}"; do indeg_now["$n"]=0; done
    for n in "${remaining[@]}"; do
      for nb in ${_adj[$n]}; do
        # consider nb only if in remaining
        if [ -n "${indeg_now[$nb]:-}" ]; then
          indeg_now["$nb"]=$((indeg_now["$nb"] + 1))
        fi
      done
    done

    # collect ready nodes (indegree 0)
    local -a ready
    for n in "${remaining[@]}"; do
      if [ "${indeg_now[$n]}" -eq 0 ]; then ready+=("$n"); fi
    done

    if [ "${#ready[@]}" -eq 0 ]; then
      log_error "Estado incorreto: não há nodes prontos, possível ciclo não detectado"
      return 1
    fi

    # process ready nodes: either parallel or sequential
    if [ "$PARALLEL_JOBS" -gt 1 ] && [ "${#ready[@]}" -gt 1 ]; then
      log_info "Instalando ${#ready[@]} dependências em paralelo (jobs=$PARALLEL_JOBS): ${ready[*]}"
      # run installations in parallel but capture failures
      local -a pids nodes_order
      nodes_order=("${ready[@]}")
      local -A rcmap
      for n in "${nodes_order[@]}"; do
        (
          ensure_node_satisfied "$n" "$no_upgrade"
          rc=$?
          if [ $rc -eq 100 ]; then
            log_info "Instalando $n ..."
            cmd_build "$n" || exit 2
            exit 0
          elif [ $rc -eq 0 ]; then
            log_info "Skip $n (já ok)"
            exit 0
          else
            log_error "Erro verificando $n (code $rc)"
            exit 1
          fi
        ) &
        pids+=($!)
      done

      # wait and check pids
      local fail=0
      for pid in "${pids[@]}"; do
        wait "$pid" || { fail=1; }
      done
      if [ $fail -ne 0 ]; then
        log_error "Falha durante instalações paralelas"
        return 1
      fi
    else
      # sequential
      for n in "${ready[@]}"; do
        ensure_node_satisfied "$n" "$no_upgrade"
        local rc=$?
        if [ $rc -eq 0 ]; then
          log_info "Skip $n (já ok)"
        elif [ $rc -eq 100 ]; then
          log_info "Instalando $n ..."
          if ! cmd_build "$n"; then
            log_error "Falha ao construir $n"
            return 1
          fi
        else
          log_error "Erro verificando $n (code $rc)"
          return 1
        fi
      done
    fi

    # remove ready from remaining
    local -a newrem
    for rr in "${remaining[@]}"; do
      local keep=1
      for rrd in "${ready[@]}"; do
        if [ "$rr" = "$rrd" ]; then keep=0; break; fi
      done
      if [ "$keep" -eq 1 ]; then newrem+=("$rr"); fi
    done
    remaining=("${newrem[@]}")
  done

  return 0
}

# ---------- CLI entry ----------
cmd_deps(){
  local port="$1"
  local action="${2:-topo}"
  local flag3="$3"

  [ -n "$port" ] || { log_error "Uso: package deps <categoria/port> [tree|topo|graphviz|install|dry-run] [--no-upgrade]"; return 2; }

  build_graph "$port"

  case "$action" in
    tree) print_tree "$port" ;;
    topo) topo_sort ;;
    graphviz) graphviz_dot ;;
    install) resolve_and_install_deps "$port" "" "${flag3:-}" ;;
    dry-run) resolve_and_install_deps "$port" "--dry-run" "${flag3:-}" ;;
    *)
      log_error "Ação desconhecida: $action"
      return 2
      ;;
  esac
}

# ---------- export helpers ----------
export -f cmd_deps build_graph topo_sort graphviz_dot resolve_and_install_deps

# EOF
