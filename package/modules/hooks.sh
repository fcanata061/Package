#!/usr/bin/env bash
# package/modules/hooks.sh
# Executa hooks definidos dentro do Makefile do port

set -euo pipefail

# Configuração global
[ -f /etc/package.conf ] && source /etc/package.conf || true
PORTSDIR=${PORTSDIR:-/usr/ports}

# Logging fallback
log_info(){ echo "[hooks][INFO] $*"; }
log_warn(){ echo "[hooks][WARN] $*"; }
log_error(){ echo "[hooks][ERROR] $*" >&2; }

# Extrai valor de variável de um Makefile
get_make_var() {
  local makefile="$1" var="$2"
  awk -v v="$var" '
    $0 ~ "^[[:space:]]*"v"[[:space:]]*[:=+]" {
      line=$0
      while (sub(/\\$/,"",line) && getline next) { line=line next }
      sub("^[[:space:]]*"v"[[:space:]]*[:=+][[:space:]]*","",line)
      gsub(/^[[:space:]]+/,"",line)
      gsub(/[[:space:]]+$/,"",line)
      print line
      exit
  }' "$makefile" | sed 's/#.*//' | xargs
}

# Executa hook se definido no Makefile
run_hook() {
  local category_name="$1"  # ex: base/gcc
  local hookname="$2"       # ex: pre_build, post_install

  local makefile="$PORTSDIR/$category_name/Makefile"
  if [ ! -f "$makefile" ]; then
    log_warn "Makefile não encontrado: $makefile"
    return 0
  fi

  local cmd
  cmd=$(get_make_var "$makefile" "$hookname")
  if [ -n "$cmd" ]; then
    log_info "Executando hook $hookname de $category_name"
    ( cd "$PORTSDIR/$category_name" && eval "$cmd" )
  fi
}

export -f run_hook get_make_var
