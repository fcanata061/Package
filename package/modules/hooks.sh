#!/usr/bin/env bash
# hooks.sh - módulo para gerenciar e executar hooks de portas
# Fornece: run_hook PORT_ID HOOK_NAME [ARGS...]
# Suporta várias formas de hooks (por-port, global, Makefile)
# - Diretórios de hooks por port: <portdir>/hooks.d/<hookname>.d/*.sh
# - Diretórios de hooks por port (compat): <portdir>/hooks/<hookname>/*.sh
# - Arquivos de hook únicos: <portdir>/hooks/<hookname>.sh
# - Variáveis no Makefile: HOOK_<HOOKNAME> (ex: HOOK_pre-build)
# - Diretório global: $HOOKS_GLOBAL_DIR/<hookname>.d/*.sh

set -euo pipefail
IFS=$'\n\t'

MODULE_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
HOOKS_GLOBAL_DIR=${HOOKS_GLOBAL_DIR:-"/usr/share/package/hooks"}
PORTSDIR=${PORTSDIR:-/usr/ports}
LOG_DIR=${LOG_DIR:-/var/log/package}

mkdir -p "$LOG_DIR"

# Logging mínimo (se o sistema já tiver log_info etc, usaremos)
if ! declare -F log_info >/dev/null 2>&1; then
  log_info(){ echo "[hooks][INFO] $*"; }
fi
if ! declare -F log_warn >/dev/null 2>&1; then
  log_warn(){ echo "[hooks][WARN] $*"; }
fi
if ! declare -F log_error >/dev/null 2>&1; then
  log_error(){ echo "[hooks][ERROR] $*" >&2; }
fi

# Normaliza um nome de hook: aceita com e sem prefixos, converte para minúsculas
_norm_hook_name(){
  local hn="$1"
  # remove espaços e caracteres não alfanuméricos, trocar / por -
  echo "${hn,,}" | sed 's#[^a-z0-9_\-]#-#g'
}

# Converte um portkey (categoria_nome_sub) em path sob $PORTSDIR
# Se o argumento já é um diretório existente, retorna ele.
_portkey_to_dir(){
  local pk="$1"
  if [ -d "$pk" ]; then
    printf '%s' "$pk"
    return 0
  fi
  # se pk contém ':' ou '/' assumimos caminho
  if [[ "$pk" == */* ]] || [[ "$pk" == :* ]]; then
    if [ -d "$pk" ]; then
      printf '%s' "$pk"
      return 0
    fi
  fi
  # transforma underscores em '/'
  local candidate="${pk//_//}"
  local try1="$PORTSDIR/$candidate"
  if [ -d "$try1" ]; then
    printf '%s' "$try1"; return 0
  fi
  # alternativa: replace first '_' only (categoria/nome)
  candidate="${pk/_//}"
  try1="$PORTSDIR/$candidate"
  if [ -d "$try1" ]; then
    printf '%s' "$try1"; return 0
  fi
  # fallback: se existir como diretório relativo
  if [ -d "$pk" ]; then
    printf '%s' "$pk"; return 0
  fi
  # não encontrado
  return 1
}

# Executa todos scripts em um diretório (ordenados), ignorando arquivos não-executáveis
_run_hook_dir(){
  local dir="$1" port_dir="$2" hook="$3" logfile="$4"
  [ -d "$dir" ] || return 0
  local s
  for s in $(ls -1q "$dir" 2>/dev/null | sort); do
    local full="$dir/$s"
    if [ -f "$full" ]; then
      if [ -x "$full" ]; then
        log_info "Executando hook script: $full"
        (cd "$port_dir" && "$full" "${HOOK_ARGS[@]}") >>"$logfile" 2>&1 || {
          log_warn "Hook script $full terminou com código não-zero; continuando"
        }
      else
        log_warn "Arquivo de hook não-executável: $full (pulando)"
      fi
    fi
  done
}

# Executa um comando único (string) como hook. Pode vir do Makefile.
_run_hook_command(){
  local cmd="$1" port_dir="$2" logfile="$3"
  if [ -z "$cmd" ]; then return 0; fi
  log_info "Executando hook command: $cmd"
  (cd "$port_dir" && bash -lc "$cmd") >>"$logfile" 2>&1 || {
    log_warn "Hook command falhou (não-zero): $cmd"
  }
}

# Lê uma variável HOOK_<HOOKNAME> do Makefile do port, retorna o conteúdo
_read_makefile_hook_var(){
  local port_dir="$1" hookname="$2"
  local mf="$port_dir/Makefile"
  [ -f "$mf" ] || return 1
  # Variável nomeada HOOK_<HOOKNAME> em uppercase, com '-' substituído por '_'
  local varname="HOOK_$(echo "$hookname" | tr '[:lower:]-' '[:upper:]_')"
  awk -v v="$varname" '
    $0 ~ "^[[:space:]]*"v"[[:space:]]*=" {
      sub("^[[:space:]]*"v"[[:space:]]*=" , "")
      val=$0
      while (val ~ /\\$/) {
        sub(/\\$/,"",val)
        if (getline nx) val = val nx
        else break
      }
      sub(/^[[:space:]]+/,"",val)
      sub(/[[:space:]]+$/,"",val)
      print val
      exit
    }
  ' "$mf" | sed 's/#.*//' | xargs 2>/dev/null || true
}

# API principal: run_hook PORT_ID HOOK_NAME [ARGS...]
# PORT_ID: portkey (categoria_nome) ou caminho para portdir
# HOOK_NAME: ex: pre-build, post-install
run_hook(){
  if [ $# -lt 2 ]; then
    log_error "run_hook: uso: run_hook <port> <hook-name> [args...]"; return 2
  fi
  local port_arg="$1" hookname_raw="$2"
  shift 2
  local HOOK_ARGS=("$@")
  local hookname
  hookname=$(_norm_hook_name "$hookname_raw")

  local port_dir
  if ! port_dir=$(_portkey_to_dir "$port_arg"); then
    log_warn "run_hook: não foi possível localizar diretório do port para '$port_arg' (pulando hooks)"
    return 0
  fi

  local logfile="$LOG_DIR/$(basename "$port_dir")-${hookname}.log"
  mkdir -p "$(dirname "$logfile")"

  log_info "run_hook: port=$port_dir hook=$hookname args='${HOOK_ARGS[*]}'"

  # 1) Executar hooks locais em <portdir>/hooks.d/<hookname>.d/*.sh
  _run_hook_dir "$port_dir/hooks.d/${hookname}.d" "$port_dir" "$hookname" "$logfile"
  # compatibilidade: <portdir>/hooks/<hookname>/*.sh
  _run_hook_dir "$port_dir/hooks/${hookname}" "$port_dir" "$hookname" "$logfile"
  # compat: <portdir>/hooks/<hookname>.sh
  if [ -f "$port_dir/hooks/${hookname}.sh" ]; then
    if [ -x "$port_dir/hooks/${hookname}.sh" ]; then
      log_info "Executando hook único: $port_dir/hooks/${hookname}.sh"
      (cd "$port_dir" && "$port_dir/hooks/${hookname}.sh" "${HOOK_ARGS[@]}") >>"$logfile" 2>&1 || log_warn "Hook único retornou não-zero"
    else
      log_warn "Hook único presente mas não-executável: $port_dir/hooks/${hookname}.sh"
    fi
  fi

  # 2) Executar variável HOOK_<HOOKNAME> no Makefile, se presente
  local mf_cmd
  mf_cmd=$(_read_makefile_hook_var "$port_dir" "$hookname") || true
  if [ -n "$mf_cmd" ]; then
    _run_hook_command "$mf_cmd" "$port_dir" "$logfile"
  fi

  # 3) Executar hooks globais instalados em $HOOKS_GLOBAL_DIR/<hookname>.d/*.sh
  _run_hook_dir "$HOOKS_GLOBAL_DIR/${hookname}.d" "$port_dir" "$hookname" "$logfile"

  # 4) Se nada foi executado (arquivo vazio de log), registrar info
  if [ ! -s "$logfile" ]; then
    log_info "run_hook: nenhum hook específico executado para $hookname (port: $port_dir)"
  else
    log_info "run_hook: saída registrada em $logfile"
  fi

  return 0
}

export -f run_hook
