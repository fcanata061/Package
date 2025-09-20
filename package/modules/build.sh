#!/usr/bin/env bash
# modules/build.sh
#
# Constrói um port dentro do sandbox, aplicando patches e executando hooks.
#
# Fluxo:
#   1. Carrega Makefile e dependências
#   2. Roda hooks pre-configure
#   3. Executa ./configure (ou comando definido)
#   4. Roda hooks post-configure
#   5. Executa make (ou comando definido)
#   6. Roda hooks post-build
#   7. Executa make check (opcional)
#   8. Copia para staging (WORKDIR/<port>/staging)

set -euo pipefail

[ -f /etc/package.conf ] && source /etc/package.conf

PORTSDIR=${PORTSDIR:-/usr/ports}
WORKDIR=${WORKDIR:-/usr/ports/work}
mkdir -p "$WORKDIR"

# --- Logging helpers ---
: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_error:=:}"

if ! declare -F log_info >/dev/null; then
  log_info(){ echo "[build][INFO] $*"; }
fi
if ! declare -F log_warn >/dev/null; then
  log_warn(){ echo "[build][WARN] $*"; }
fi
if ! declare -F log_error >/dev/null; then
  log_error(){ echo "[build][ERROR] $*" >&2; }
fi

# --- Dependências internas ---
MODULESDIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
source "$MODULESDIR/hooks.sh"
source "$MODULESDIR/patch.sh"
source "$MODULESDIR/dependency.sh"
source "$MODULESDIR/sandbox.sh"
source "$MODULESDIR/fakeroot.sh"

# --- Função principal ---

build_port() {
  local port_dir="$1"
  [ -f "$port_dir/Makefile" ] || {
    log_error "Makefile não encontrado em $port_dir"
    return 1
  }

  local name version builddir staging
  name=$(make -C "$port_dir" -s -f Makefile -V PORTNAME || basename "$port_dir")
  version=$(make -C "$port_dir" -s -f Makefile -V PORTVERSION || echo "0")
  builddir="$WORKDIR/$name-$version/build"
  staging="$WORKDIR/$name-$version/staging"

  mkdir -p "$builddir" "$staging"

  log_info "=== Construindo $name-$version ==="

  # Dependências
  log_info "Resolvendo dependências de $name..."
  resolve_dependencies "$port_dir"

  # Patches
  log_info "Aplicando patches..."
  apply_patches "$port_dir"

  # Entrar no sandbox para build
  sandbox_exec "$builddir" bash -s <<EOF
    set -e
    cd "$builddir"

    # Extrair sources
    src_archive=\$(make -C "$port_dir" -s -f Makefile -V DISTFILES | awk '{print \$1}')
    src_path="$WORKDIR/$name-$version/src"
    mkdir -p "\$src_path"

    if [ -n "\$src_archive" ] && [ -f "$WORKDIR/../distfiles/\$src_archive" ]; then
      tar xf "$WORKDIR/../distfiles/\$src_archive" -C "\$src_path" --strip-components=1
    elif [ -d "$WORKDIR/../distfiles/$name" ]; then
      cp -r "$WORKDIR/../distfiles/$name"/* "\$src_path"/
    fi

    cd "\$src_path"

    # Hooks
    run_hook pre-configure "$port_dir"

    # Configuração
    configure_cmd=\$(make -C "$port_dir" -s -f Makefile -V CONFIGURE_CMD || echo "./configure --prefix=$PREFIX")
    echo "[build] Rodando configure: \$configure_cmd"
    eval \$configure_cmd

    run_hook post-configure "$port_dir"

    # Build
    run_hook pre-build "$port_dir"
    build_cmd=\$(make -C "$port_dir" -s -f Makefile -V BUILD_CMD || echo "make -j\$(nproc)")
    echo "[build] Rodando build: \$build_cmd"
    eval \$build_cmd
    run_hook post-build "$port_dir"

    # Testes opcionais
    if make -C "$port_dir" -q check >/dev/null 2>&1; then
      run_hook pre-check "$port_dir"
      echo "[build] Rodando make check"
      make check || echo "[build][WARN] Testes falharam, mas continuando"
      run_hook post-check "$port_dir"
    fi

    # Instalação em staging
    run_hook pre-install "$port_dir"
    install_cmd=\$(make -C "$port_dir" -s -f Makefile -V INSTALL_CMD || echo "make DESTDIR=$staging install")
    echo "[build] Rodando install em staging: \$install_cmd"
    eval \$install_cmd
    run_hook post-install "$port_dir"
EOF

  log_info "Build de $name-$version concluído com sucesso."
  log_info "Artefatos disponíveis em $staging"
}

# --- Export ---
export -f build_port

# Execução direta
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ $# -lt 1 ]; then
    echo "Uso: $0 <port_dir>"
    exit 1
  fi
  build_port "$1"
fi
