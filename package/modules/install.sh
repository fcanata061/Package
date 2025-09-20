#!/usr/bin/env bash
# package/modules/install.sh (revisado)
# Módulo "install" do gerenciador "package"
# - Pega staging gerado pelo build
# - Copia arquivos pro sistema usando fakeroot/sandbox quando disponível
# - Atualiza registry/local database com lista de arquivos
# - Exporta: cmd_install, install_port

set -euo pipefail

[ -f /etc/package.conf ] && source /etc/package.conf || true

PORTSDIR=${PORTSDIR:-/usr/ports}
WORKDIR=${WORKDIR:-/var/cache/package/work}
FILES_DIR=${FILES_DIR:-/var/lib/package/files}
REGISTRY_DIR=${REGISTRY_DIR:-/var/lib/package/registry}
LOG_DIR=${LOG_DIR:-/var/log/package}
PREFIX=${PREFIX:-/usr/local}

mkdir -p "$WORKDIR" "$FILES_DIR" "$REGISTRY_DIR" "$LOG_DIR"

# Logging fallbacks
: "${log_info:=:}"; : "${log_warn:=:}"; : "${log_error:=:}"; : "${log_event:=:}"
if ! declare -F log_info >/dev/null; then log_info(){ echo "[install][INFO] $*"; }; fi
if ! declare -F log_warn >/dev/null; then log_warn(){ echo "[install][WARN] $*"; }; fi
if ! declare -F log_error >/dev/null; then log_error(){ echo "[install][ERROR] $*" >&2; }; fi
if ! declare -F log_event >/dev/null; then log_event(){ :; }; fi

# Source fakeroot/sandbox/registry se existirem
MODULE_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
[ -f "$MODULE_DIR/fakeroot.sh" ] && source "$MODULE_DIR/fakeroot.sh"
[ -f "$MODULE_DIR/sandbox.sh" ] && source "$MODULE_DIR/sandbox.sh"
[ -f "$MODULE_DIR/register.sh" ] && source "$MODULE_DIR/register.sh"

# Fallbacks
if ! declare -F fakeroot_install_from_staging >/dev/null; then
  fakeroot_install_from_staging(){
    local staging="$1" port="$2"
    log_warn "fakeroot não disponível; copiando direto (pode precisar sudo)"
    if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null; then
      sudo rsync -a "$staging"/ /
    else
      rsync -a "$staging"/ /
    fi
  }
fi
if ! declare -F sandbox_exec >/dev/null; then
  sandbox_exec(){ bash -c "$*"; }
fi
if ! declare -F register_port >/dev/null; then
  register_port(){ log_warn "register_port não implementado: $1"; }
fi

# Helper: port key
_port_key_from_dir(){ local dir="$1" rel="${dir#$PORTSDIR/}"; echo "${rel//\//_}"; }

install_port(){
  local port_dir="$1"
  [ -d "$port_dir" ] || { log_error "install_port: diretório não encontrado: $port_dir"; return 1; }
  [ -f "$port_dir/Makefile" ] || { log_error "install_port: Makefile não encontrado"; return 1; }

  local mf="$port_dir/Makefile"
  local portname portver portkey workdir staging files_list

  portname=$(awk '/^PORTNAME[ \t]*[:+]?=/ {print $3; exit}' "$mf" || true)
  portver=$(awk '/^PORTVERSION[ \t]*[:+]?=/ {print $3; exit}' "$mf" || true)
  [ -z "$portname" ] && portname=$(basename "$port_dir")
  [ -z "$portver" ] && portver="0.0.0"

  portkey=$(_port_key_from_dir "$port_dir")
  workdir="$WORKDIR/$portkey-$portver"
  staging="$workdir/staging"
  files_list="$FILES_DIR/${portkey}.list"

  if [ ! -d "$staging" ]; then
    log_error "Staging não encontrado para $portkey ($staging) — rode 'package build' antes"
    return 1
  fi

  log_info "=== Iniciando instalação: $portkey v$portver ==="
  log_event "install" "$portkey" "$portver" "start"

  # Executa instalação real (fakeroot dentro do sandbox se definido)
  if [ "${SANDBOX_METHOD:-none}" != "none" ]; then
    log_info "Executando instalação dentro do sandbox ($SANDBOX_METHOD)"
    sandbox_exec "fakeroot_install_from_staging '$staging' '$portkey'"
  else
    fakeroot_install_from_staging "$staging" "$portkey"
  fi

  # Atualiza registry
  if [ -f "$files_list" ]; then
    register_port "$portkey" "$portver" "$files_list"
  else
    log_warn "Lista de arquivos não encontrada: $files_list"
  fi

  log_info "Instalação concluída para $portkey v$portver"
  log_event "install" "$portkey" "$portver" "success"
  return 0
}

cmd_install(){
  local port="$1"
  [ -n "$port" ] || { log_error "Uso: package install <category/name>"; return 2; }
  local port_dir="$PORTSDIR/$port"
  if [ ! -d "$port_dir" ]; then
    log_error "Port não encontrado: $port_dir"
    return 1
  fi
  install_port "$port_dir"
}

export -f cmd_install install_port

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ $# -lt 1 ]; then
    echo "Uso: $0 <category/name> | <portdir>" >&2
    exit 1
  fi
  if [ -d "$1" ] && [ -f "$1/Makefile" ]; then
    install_port "$1"
  else
    cmd_install "$1"
  fi
fi
