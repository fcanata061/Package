#!/usr/bin/env bash
# modules/build.sh
# --- Gerenciamento de build de ports ---
#
# Fluxo:
#   1. Resolver dependências (dependency.sh)
#   2. Preparar sandbox (sandbox.sh)
#   3. Executar hooks (hooks.sh)
#   4. Configurar -> Compilar -> Testar
#   5. Instalar em STAGEDIR
#   6. Instalar no sistema real via fakeroot (fakeroot.sh)
#   7. Registrar log e banco de pacotes (logs.sh, register.sh)

PORTSDIR=${PORTSDIR:-/usr/ports}
STAGING_ROOT=${STAGING_ROOT:-/var/tmp/package/stage}
INSTALLED_DB=${INSTALLED_DB:-/var/lib/package/installed}

mkdir -p "$STAGING_ROOT"

# injeção de dependências (funções externas)
: "${resolve_all:=:}"
: "${fakeroot_install:=:}"
: "${hooks_run:=:}"
: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_error:=:}"
: "${register_install:=:}"

if ! declare -F log_info >/dev/null; then log_info(){ echo "[build][INFO] $*"; }; fi
if ! declare -F log_warn >/dev/null; then log_warn(){ echo "[build][WARN] $*"; }; fi
if ! declare -F log_error >/dev/null; then log_error(){ echo "[build][ERROR] $*" >&2; }; fi

# -----------------------------------------------------------------------------
# Extrair variáveis do Makefile
# -----------------------------------------------------------------------------
get_make_var() {
  local port_path="$1"
  local var="$2"
  local makefile="$PORTSDIR/$port_path/Makefile"
  grep "^$var=" "$makefile" | sed "s/^$var=//"
}

# -----------------------------------------------------------------------------
# Executar build no sandbox
# -----------------------------------------------------------------------------
build_in_sandbox() {
  local port_path="$1"
  local sandbox_dir="$2"
  local stagedir="$3"

  local workdir="$sandbox_dir/work"
  mkdir -p "$workdir"

  local name version src_url
  name=$(get_make_var "$port_path" NAME)
  version=$(get_make_var "$port_path" VERSION)
  src_url=$(get_make_var "$port_path" MASTER_SITES)

  # 1. Pré-configure hook
  hooks_run "$port_path" pre-configure "$workdir" || return 1

  # 2. Extrair código-fonte
  log_info "Extraindo código de $port_path"
  tarball="$PORTSDIR/$port_path/distfiles/${name}-${version}.tar.gz"
  [ -f "$tarball" ] || { log_error "Tarball não encontrado: $tarball"; return 1; }
  tar -xf "$tarball" -C "$workdir" || return 1

  srcdir="$workdir/${name}-${version}"
  [ -d "$srcdir" ] || { log_error "Diretório fonte não encontrado: $srcdir"; return 1; }

  cd "$srcdir" || return 1

  # 3. Configure
  hooks_run "$port_path" pre-configure "$srcdir"
  if [ -x "./configure" ]; then
    log_info "Rodando ./configure"
    ./configure --prefix=/usr/local || return 1
  fi
  hooks_run "$port_path" post-configure "$srcdir"

  # 4. Build
  log_info "Compilando $port_path"
  make || return 1

  # 5. Test (opcional)
  if make -n check >/dev/null 2>&1; then
    log_info "Rodando testes"
    make check || log_warn "Alguns testes falharam em $port_path"
  fi

  # 6. Instalar em STAGEDIR
  log_info "Instalando em STAGEDIR $stagedir"
  mkdir -p "$stagedir"
  hooks_run "$port_path" pre-install "$srcdir"
  make DESTDIR="$stagedir" install || return 1
  hooks_run "$port_path" post-install "$srcdir"

  return 0
}

# -----------------------------------------------------------------------------
# Função principal: cmd_build
# -----------------------------------------------------------------------------
cmd_build() {
  local port_path="$1"
  [ -n "$port_path" ] || { log_error "Uso: package build <categoria/port>"; return 2; }

  log_info "Iniciando build de $port_path"

  # 1. Resolver dependências
  log_info "Resolvendo dependências..."
  resolve_all "$port_path" "|" "|" || return 1

  # 2. Criar sandbox
  sandbox_dir="$(mktemp -d /var/tmp/package-sandbox.XXXXXX)"
  stagedir="$STAGING_ROOT/$(echo "$port_path" | tr '/' '_')"
  mkdir -p "$stagedir"

  # 3. Rodar build dentro do sandbox
  if ! build_in_sandbox "$port_path" "$sandbox_dir" "$stagedir"; then
    log_error "Build falhou para $port_path"
    rm -rf "$sandbox_dir"
    return 1
  fi

  # 4. Instalar com fakeroot
  if ! fakeroot_install "$stagedir" "$port_path"; then
    log_error "Instalação falhou para $port_path"
    rm -rf "$sandbox_dir"
    return 1
  fi

  # 5. Registrar no banco de instalados
  local version
  version=$(get_make_var "$port_path" VERSION)
  register_install "$port_path" "$version" || return 1

  # 6. Rodar hooks pós-remove
  hooks_run "$port_path" post-install-system "/"

  # 7. Limpeza
  rm -rf "$sandbox_dir"

  log_info "Build concluído para $port_path"
}
