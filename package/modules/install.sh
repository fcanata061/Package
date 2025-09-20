#!/usr/bin/env bash
# modules/install.sh
#
# Instala um port previamente construído (via build.sh) no sistema.
# Fluxo:
#   1. Localiza staging (WORKDIR/<port>/staging)
#   2. Executa hooks pre-install-system
#   3. Copia arquivos com fakeroot
#   4. Executa hooks post-install-system
#   5. Registra no banco de pacotes
#   6. Ativa serviços, se houver

set -euo pipefail

[ -f /etc/package.conf ] && source /etc/package.conf

PORTSDIR=${PORTSDIR:-/usr/ports}
WORKDIR=${WORKDIR:-/usr/ports/work}
DBDIR=${DBDIR:-/var/lib/package/db}
PREFIX=${PREFIX:-/usr/local}

mkdir -p "$WORKDIR" "$DBDIR"

# --- Logging ---
: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_error:=:}"

if ! declare -F log_info >/dev/null; then
  log_info(){ echo "[install][INFO] $*"; }
fi
if ! declare -F log_warn >/dev/null; then
  log_warn(){ echo "[install][WARN] $*"; }
fi
if ! declare -F log_error >/dev/null; then
  log_error(){ echo "[install][ERROR] $*" >&2; }
fi

# --- Dependências internas ---
MODULESDIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
source "$MODULESDIR/hooks.sh"
source "$MODULESDIR/fakeroot.sh"
source "$MODULESDIR/register.sh"
source "$MODULESDIR/service.sh"

# --- Função principal ---
install_port() {
  local port_dir="$1"

  [ -f "$port_dir/Makefile" ] || {
    log_error "Makefile não encontrado em $port_dir"
    return 1
  }

  local name version staging
  name=$(make -C "$port_dir" -s -f Makefile -V PORTNAME || basename "$port_dir")
  version=$(make -C "$port_dir" -s -f Makefile -V PORTVERSION || echo "0")
  staging="$WORKDIR/$name-$version/staging"

  [ -d "$staging" ] || {
    log_error "Staging não encontrado para $name-$version. Execute build.sh antes."
    return 1
  }

  log_info "=== Instalando $name-$version no sistema ==="

  # Hooks pre-install-system
  run_hook pre-install-system "$port_dir"

  # Copiar arquivos com fakeroot
  log_info "Copiando arquivos de $staging para $PREFIX"
  fakeroot_exec rsync -a "$staging/" "$PREFIX/"

  # Hooks post-install-system
  run_hook post-install-system "$port_dir"

  # Registrar no banco
  log_info "Registrando $name-$version"
  register_package "$name" "$version" "$staging"

  # Ativar serviços (se definidos no port)
  if [ -d "$port_dir/service" ]; then
    log_info "Ativando serviços para $name"
    for svc in "$port_dir"/service/*; do
      [ -f "$svc" ] || continue
      service_install "$svc"
    done
  fi

  log_info "Instalação de $name-$version concluída."
}

export -f install_port

# Execução direta
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ $# -lt 1 ]; then
    echo "Uso: $0 <port_dir>"
    exit 1
  fi
  install_port "$1"
fi
