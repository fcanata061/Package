#!/usr/bin/env bash
# modules/install.sh
#
# Instala um port previamente construído (via build.sh) no sistema.
# Inclui rollback em caso de falha, manifest JSON e integração com logs.
#
# Fluxo:
#   1. Localiza staging (WORKDIR/<port>/staging)
#   2. Executa hooks pre-install-system
#   3. Copia arquivos com fakeroot (rsync)
#   4. Gera manifest JSON
#   5. Executa hooks post-install-system
#   6. Registra no banco
#   7. Ativa serviços, se houver

set -euo pipefail

[ -f /etc/package.conf ] && source /etc/package.conf

PORTSDIR=${PORTSDIR:-/usr/ports}
WORKDIR=${WORKDIR:-/usr/ports/work}
DBDIR=${DBDIR:-/var/lib/package/db}
LOGDIR=${LOGDIR:-/var/log/package}
PREFIX=${PREFIX:-/usr/local}
TRASHDIR=${TRASHDIR:-/var/lib/package/trash}

mkdir -p "$WORKDIR" "$DBDIR" "$LOGDIR" "$TRASHDIR"

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
source "$MODULESDIR/logs.sh"

# --- Funções auxiliares ---

_manifest_file() {
  local name="$1" version="$2"
  echo "$DBDIR/$name-$version.manifest.json"
}

_generate_manifest() {
  local staging="$1" name="$2" version="$3"
  local manifest="$(_manifest_file "$name" "$version")"

  log_info "Gerando manifest $manifest"
  {
    echo "{"
    echo "  \"name\": \"$name\","
    echo "  \"version\": \"$version\","
    echo "  \"files\": ["
    find "$staging" -type f | sed 's#^'"$staging"'#/usr/local#' | sed 's/$/,/' | sed '$ s/,$//'
    echo "  ]"
    echo "}"
  } > "$manifest"
}

# --- Função principal ---

install_port() {
  local port_dir="$1"

  [ -f "$port_dir/Makefile" ] || {
    log_error "Makefile não encontrado em $port_dir"
    return 1
  }

  local name version staging manifest
  name=$(make -C "$port_dir" -s -f Makefile -V PORTNAME || basename "$port_dir")
  version=$(make -C "$port_dir" -s -f Makefile -V PORTVERSION || echo "0")
  staging="$WORKDIR/$name-$version/staging"
  manifest="$(_manifest_file "$name" "$version")"

  [ -d "$staging" ] || {
    log_error "Staging não encontrado para $name-$version. Execute build.sh antes."
    return 1
  }

  log_info "=== Instalando $name-$version no sistema ==="
  log_event "install" "$name" "$version" "start"

  # Hooks pre-install-system
  run_hook pre-install-system "$port_dir"

  # Rollback: mover arquivos já existentes para TRASHDIR
  local rollback_dir="$TRASHDIR/${name}-${version}-$(date +%s)"
  mkdir -p "$rollback_dir"
  log_info "Preparando rollback em $rollback_dir"

  rsync -a --ignore-existing "$staging/" "$PREFIX/" || true
  rsync -a --existing "$PREFIX/" "$rollback_dir/" || true

  # Copiar staging para sistema (com fakeroot)
  log_info "Copiando arquivos para $PREFIX"
  if ! fakeroot_exec rsync -a "$staging/" "$PREFIX/"; then
    log_error "Falha na cópia, iniciando rollback"
    rsync -a "$rollback_dir/" "$PREFIX/"
    log_event "install" "$name" "$version" "failed"
    return 1
  fi

  # Manifest JSON
  _generate_manifest "$staging" "$name" "$version"

  # Hooks post-install-system
  run_hook post-install-system "$port_dir"

  # Registrar no banco
  log_info "Registrando $name-$version"
  register_package "$name" "$version" "$staging"

  # Ativar serviços (systemd)
  if [ -d "$port_dir/service" ]; then
    log_info "Ativando serviços para $name"
    for svc in "$port_dir"/service/*; do
      [ -f "$svc" ] || continue
      service_install "$svc"
    done
  fi

  log_info "Instalação de $name-$version concluída."
  log_event "install" "$name" "$version" "success"
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
