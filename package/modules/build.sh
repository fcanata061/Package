#!/usr/bin/env bash
# modules/build.sh
# --- Sistema completo de build de ports ---

PORTSDIR=${PORTSDIR:-/usr/ports}
STAGING_ROOT=${STAGING_ROOT:-/var/tmp/package/stage}
INSTALLED_DB=${INSTALLED_DB:-/var/lib/package/installed}
BUILD_LOG_DIR=${BUILD_LOG_DIR:-/var/log/package/builds}

mkdir -p "$STAGING_ROOT" "$BUILD_LOG_DIR"

# injeção de dependências externas
: "${resolve_all:=:}"
: "${fakeroot_install:=:}"
: "${patch_apply:=:}"
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
# Função principal de build dentro do sandbox
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

  local tarball="$PORTSDIR/$port_path/distfiles/${name}-${version}.tar.gz"
  [ -f "$tarball" ] || { log_error "Tarball não encontrado: $tarball"; return 1; }

  log_info "Extraindo código-fonte para $workdir"
  tar -xf "$tarball" -C "$workdir" || return 1

  srcdir="$workdir/${name}-${version}"
  [ -d "$srcdir" ] || { log_error "Diretório fonte não encontrado: $srcdir"; return 1; }

  cd "$srcdir" || return 1

  # --- fase de patch ---
  hooks_run "$port_path" pre-patch "$srcdir"
  patch_apply "$port_path" "$srcdir" || return 1
  hooks_run "$port_path" post-patch "$srcdir"

  # --- fase de configure ---
  hooks_run "$port_path" pre-configure "$srcdir"
  if [ -x "./configure" ]; then
    log_info "Rodando ./configure"
    ./configure --prefix=/usr/local || return 1
  fi
  hooks_run "$port_path" post-configure "$srcdir"

  # --- fase de build ---
  hooks_run "$port_path" pre-build "$srcdir"
  log_info "Compilando $port_path"
  make || return 1
  hooks_run "$port_path" post-build "$srcdir"

  # --- fase de test ---
  if make -n check >/dev/null 2>&1; then
    log_info "Rodando testes"
    make check || log_warn "Alguns testes falharam em $port_path"
  fi

  # --- fase de install ---
  hooks_run "$port_path" pre-install "$srcdir"
  log_info "Instalando em STAGEDIR $stagedir"
  mkdir -p "$stagedir"
  make DESTDIR="$stagedir" install || return 1
  hooks_run "$port_path" post-install "$srcdir"

  return 0
}

# -----------------------------------------------------------------------------
# Função principal cmd_build
# -----------------------------------------------------------------------------
cmd_build() {
  local port_path="$1"
  [ -n "$port_path" ] || { log_error "Uso: package build <categoria/port>"; return 2; }

  local logfile="$BUILD_LOG_DIR/$(echo "$port_path" | tr '/' '_').log"
  rm -f "$logfile"

  log_info "=== Iniciando build de $port_path ==="
  exec 3>&1 1>>"$logfile" 2>&1  # redireciona saída para log

  # --- dependências ---
  log_info "[fase] Resolvendo dependências"
  resolve_all "$port_path" "|" "|" || { log_error "Falha nas dependências"; return 1; }

  # --- criar sandbox ---
  log_info "[fase] Criando sandbox"
  sandbox_dir="$(mktemp -d /var/tmp/package-sandbox.XXXXXX)"
  stagedir="$STAGING_ROOT/$(echo "$port_path" | tr '/' '_')"
  rm -rf "$stagedir" && mkdir -p "$stagedir"

  # --- build no sandbox ---
  if ! build_in_sandbox "$port_path" "$sandbox_dir" "$stagedir"; then
    log_error "Build falhou para $port_path (veja $logfile)"
    rm -rf "$sandbox_dir"
    exec 1>&3 3>&-  # restaura saída
    return 1
  fi

  # --- instalar no sistema real ---
  log_info "[fase] Instalando no sistema real via fakeroot"
  if ! fakeroot_install "$stagedir" "$port_path"; then
    log_error "Instalação falhou para $port_path"
    rm -rf "$sandbox_dir"
    exec 1>&3 3>&-
    return 1
  fi

  # --- registrar ---
  log_info "[fase] Registrando port"
  local version
  version=$(get_make_var "$port_path" VERSION)
  register_install "$port_path" "$version" || { log_error "Registro falhou"; return 1; }

  # --- hooks pós instalação no sistema ---
  hooks_run "$port_path" post-install-system "/"

  # --- limpeza ---
  rm -rf "$sandbox_dir"
  log_info "=== Build concluído com sucesso para $port_path ==="

  exec 1>&3 3>&-  # restaura saída
}
