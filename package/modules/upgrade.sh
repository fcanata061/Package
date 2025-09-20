#!/usr/bin/env bash
# modules/upgrade.sh
# Upgrades de ports: single, --all, --force, --check-only, rollback best-effort.
# Exports: cmd_upgrade

set -euo pipefail

# load config
[ -f /etc/package.conf ] && source /etc/package.conf

# defaults
PORTSDIR=${PORTSDIR:-/usr/ports}
INSTALLED_DB=${INSTALLED_DB:-/var/lib/package/installed}
PARALLEL_JOBS=${PARALLEL_JOBS:-1}
AUTO_UPGRADE_NO=${AUTO_UPGRADE_NO:-yes}
UNWIND_ON_FAIL=${UNWIND_ON_FAIL:-yes}
MAX_RETRY_UPGRADE=${MAX_RETRY_UPGRADE:-1}
USER_AGENT=${USER_AGENT:-"package-upgrade/1.0"}

# logging fallbacks
: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_error:=:}"
: "${log_port:=:}"
if ! declare -F log_info >/dev/null; then log_info(){ echo "[upgrade][INFO] $*"; }; fi
if ! declare -F log_warn >/dev/null; then log_warn(){ echo "[upgrade][WARN] $*"; }; fi
if ! declare -F log_error >/dev/null; then log_error(){ echo "[upgrade][ERROR] $*" >&2; }; fi
if ! declare -F log_port >/dev/null; then log_port(){ echo "[$1] $2"; }; fi

# external hooks/fns (fallbacks)
if ! declare -F register_is_installed >/dev/null; then
  register_is_installed(){ grep -q "^$1 " "$INSTALLED_DB" 2>/dev/null || return 1; }
fi
if ! declare -F get_installed_version >/dev/null; then
  get_installed_version(){
    local p="$1"; grep "^$p " "$INSTALLED_DB" 2>/dev/null | awk '{print $2}' || echo ""
  }
fi
if ! declare -F register_install >/dev/null; then
  register_install(){ log_warn "register_install não implementado; pretendendo registrar $1 $2"; }
fi
if ! declare -F cmd_deps >/dev/null; then
  cmd_deps(){ log_warn "cmd_deps não implementado; pulando resolução de dependências para $1"; return 0; }
fi
if ! declare -F cmd_build >/dev/null; then
  cmd_build(){ log_error "cmd_build não implementado; não é possível construir $1"; return 2; }
fi
if ! declare -F cmd_install >/dev/null; then
  cmd_install(){ log_warn "cmd_install não implementado; assumindo cmd_build já instalou $1"; return 0; }
fi
if ! declare -F run_hook >/dev/null; then
  run_hook(){ log_info "run_hook não implementado: hook $2 para $1"; return 0; }
fi
if ! declare -F register_action >/dev/null; then
  register_action(){ log_info "register_action não implementado: $*"; }
fi

# helpers
_makefile_var(){ local mf="$1" var="$2"; [ -f "$mf" ] || return 1; awk -v v="$var" '$0 ~ "^[[:space:]]*"v"[[:space:]]*=" { sub("^[[:space:]]*"v"[[:space:]]*=",""); val=$0; while (val ~ /\\$/){ sub(/\\$/,"",val); if (getline nx) val = val nx; else break; } gsub(/^[[:space:]]+/,"",val); gsub(/[[:space:]]+$/,"",val); print val }' "$mf" | sed 's/#.*//' | xargs || true; }
_port_version_from_mf(){ local mf="$1" v; for var in VERSION DISTVERSION PORTVERSION; do v=$(_makefile_var "$mf" "$var"); [ -n "$v" ] && { printf '%s' "$v"; return 0; }; done; printf '%s' "0.0.0"; }

_vnorm(){ printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
version_gt(){ local a=$(_vnorm "$1") b=$(_vnorm "$2"); [ -z "$a" ] && return 1; [ -z "$b" ] && return 0; [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)" = "$a" ] && [ "$a" != "$b" ]; }

# build in staging: tries to build with DESTDIR staging dir; fallback best-effort
_try_build_in_staging(){
  local port="$1" staging="$2"
  # attempt: set DESTDIR and run cmd_build
  log_info "Tentando build em staging: $staging"
  export DESTDIR="$staging"
  if cmd_build "$port"; then
    log_info "Build em staging completo para $port"
    return 0
  fi
  log_warn "cmd_build com DESTDIR falhou para $port; tentando cmd_build sem DESTDIR"
  unset DESTDIR
  if cmd_build "$port"; then
    log_info "Build normal completou para $port (não suportou staging)"
    return 0
  fi
  log_error "Build falhou para $port"
  return 1
}

# install from staging: tries cmd_install (with DESTDIR), fallback best-effort
_try_install_from_staging(){
  local port="$1" staging="$2"
  export DESTDIR="$staging"
  if declare -F cmd_install >/dev/null; then
    if cmd_install "$port"; then
      log_info "Instalação a partir de staging bem-sucedida para $port"
      unset DESTDIR
      return 0
    fi
    log_warn "cmd_install com DESTDIR falhou para $port"
  fi
  unset DESTDIR
  # fallback: maybe cmd_build already installed in system; assume success only if register_is_installed returns true
  if register_is_installed "$port"; then
    log_info "Assumindo instalação existente para $port após build"
    return 0
  fi
  log_error "Instalação a partir de staging não foi possível para $port"
  return 1
}

# perform single upgrade (tries staging build -> install -> remove old if needed)
_perform_upgrade_one(){
  local port="$1" force="${2:-0}" check_only="${3:-0}" no_upgrade_flag="${4:-0}"
  [ -n "$port" ] || return 2

  if [ "${AUTO_UPGRADE_NO:-yes}" = "yes" ] && [ "$force" != "1" ] && [ "$check_only" != "1" ]; then
    log_warn "Upgrades automáticos estão desabilitados por configuração (AUTO_UPGRADE_NO=yes)"
    return 1
  fi

  if ! register_is_installed "$port"; then
    log_warn "Pacote $port não está instalado; ignorando upgrade"
    return 0
  fi

  local mf="$PORTSDIR/$port/Makefile"
  [ -f "$mf" ] || { log_error "Makefile não encontrado para $port"; return 1; }

  local ver_inst ver_new
  ver_inst=$(get_installed_version "$port" 2>/dev/null || echo "")
  ver_new=$(_port_version_from_mf "$mf")

  if [ "$check_only" = "1" ]; then
    if version_gt "$ver_new" "$ver_inst" || [ "$force" = "1" ]; then
      printf '%s (installed=%s available=%s)\n' "$port" "$ver_inst" "$ver_new"
    fi
    return 0
  fi

  if [ "$ver_inst" = "$ver_new" ] && [ "$force" != "1" ]; then
    log_info "[$port] já está na versão $ver_inst; use --force para reinstalar"
    return 0
  fi

  log_info "[$port] Upgrade: $ver_inst -> $ver_new"
  log_port "$port" "Iniciando upgrade $ver_inst -> $ver_new"

  # pre-upgrade hook
  run_hook "$port" "pre_upgrade" || { log_error "pre_upgrade hook falhou para $port"; return 1; }

  # deps
  if ! cmd_deps "$port" install; then
    log_error "Falha ao resolver dependências para $port"
    return 1
  fi

  # attempt build in staging
  local staging
  staging="$(mktemp -d -p /tmp package-staging-XXXXXX)" || staging="/tmp/package-staging-$$"
  local attempt=0 built=0
  while [ $attempt -le "$MAX_RETRY_UPGRADE" ]; do
    attempt=$((attempt+1))
    if _try_build_in_staging "$port" "$staging"; then built=1; break; fi
    log_warn "Tentativa $attempt para build de $port falhou"
    sleep 1
  done

  if [ $built -ne 1 ]; then
    log_error "Não foi possível construir nova versão de $port"
    rm -rf "$staging" 2>/dev/null || true
    return 1
  fi

  # attempt install from staging
  if ! _try_install_from_staging "$port" "$staging"; then
    log_error "Instalação da nova versão falhou; tentando rollback se configurado"
    if [ "${UNWIND_ON_FAIL:-yes}" = "yes" ] && [ -n "$ver_inst" ]; then
      log_info "Tentando restaurar versão anterior $ver_inst para $port"
      # try to rebuild/install the previous version; best-effort:
      if cmd_build "${port}@${ver_inst}" 2>/dev/null || cmd_build "$port" 2>/dev/null; then
        log_info "Rollback: tentei reconstruir versão anterior (melhor esforço)"
      else
        log_error "Rollback falhou (não é suportado no ambiente). Manual recovery pode ser necessário."
      fi
    fi
    rm -rf "$staging" 2>/dev/null || true
    return 1
  fi

  # post-upgrade hook
  run_hook "$port" "post_upgrade" || log_warn "post_upgrade hook retornou falha para $port (mas prosseguindo)"

  # register new version
  register_install "$port" "$ver_new"
  register_action "upgrade" "$port" "success"

  # cleanup staging
  rm -rf "$staging" 2>/dev/null || true

  log_info "[$port] Upgrade concluído: $ver_new"
  return 0
}

# top-level cmd
cmd_upgrade(){
  local force=0 check_only=0 all=0 no_upgrade_flag=0
  local ports=()

  # parse args
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      --check-only|--dry-run) check_only=1; shift ;;
      --all) all=1; shift ;;
      --no-upgrade) no_upgrade_flag=1; shift ;;
      --) shift; break ;;
      -*)
        log_error "Opção desconhecida: $1"; return 2 ;;
      *) ports+=("$1"); shift ;;
    esac
  done

  if [ "$all" -eq 1 ]; then
    # build list from INSTALLED_DB (first column is port)
    if [ -f "$INSTALLED_DB" ]; then
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        ports+=("$(printf '%s' "$line" | awk '{print $1}')")
      done < "$INSTALLED_DB"
    else
      log_error "INSTALLED_DB não encontrado em $INSTALLED_DB"
      return 1
    fi
  fi

  if [ "${#ports[@]}" -eq 0 ]; then
    log_error "Uso: package upgrade <port...> [--all] [--force] [--check-only]"
    return 2
  fi

  # pre-upgrade_all hook
  run_hook "global" "pre_upgrade_all" || true

  # process ports (se PARALLEL_JOBS>1, podemos paralelizar simples)
  if [ "$PARALLEL_JOBS" -gt 1 ] && [ "$check_only" -ne 1 ]; then
    # parallel execution but limited: best-effort
    local pids=()
    for p in "${ports[@]}"; do
      _perform_upgrade_one "$p" "$force" "$check_only" "$no_upgrade_flag" &
      pids+=($!)
      # throttle
      while [ "${#pids[@]}" -ge "$PARALLEL_JOBS" ]; do
        wait -n || true
        # clean finished pids
        local newp=()
        for pid in "${pids[@]}"; do
          if kill -0 "$pid" 2>/dev/null; then newp+=("$pid"); fi
        done
        pids=("${newp[@]}")
      done
    done
    # wait remaining
    for pid in "${pids[@]}"; do wait "$pid" || true; done
  else
    for p in "${ports[@]}"; do
      _perform_upgrade_one "$p" "$force" "$check_only" "$no_upgrade_flag" || true
    done
  fi

  # post-upgrade_all hook
  run_hook "global" "post_upgrade_all" || true

  return 0
}

export -f cmd_upgrade
