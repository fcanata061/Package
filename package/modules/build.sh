#!/usr/bin/env bash
# package/modules/build.sh (revisado)
# Módulo "build" para o gerenciador "package"
# Exporta: cmd_build, build_port
# - Construção out-of-source quando aplicável
# - Integração com fetch/patch/hooks/dependency/fakeroot/sandbox (se existirem)
# - Gera staging dir, lista de arquivos e manifest JSON

set -euo pipefail

# Load global config if present
[ -f /etc/package.conf ] && source /etc/package.conf || true

# Defaults (overridable via /etc/package.conf)
PORTSDIR=${PORTSDIR:-/usr/ports}
WORKDIR=${WORKDIR:-/var/cache/package/work}
DISTDIR=${DISTDIR:-/var/cache/package/distfiles}
PREFIX=${PREFIX:-/usr/local}
# MAKEFLAGS may be a string like "-j4"; keep as-is and pass-through
MAKEFLAGS=${MAKEFLAGS:--j$(nproc)}
CONFIGURE_ARGS=${CONFIGURE_ARGS:-}
HOOKS_RUN_MAKEFILE=${HOOKS_RUN_MAKEFILE:-yes}
VERIFY_CHECKSUMS=${VERIFY_CHECKSUMS:-yes}
FILES_DIR=${FILES_DIR:-/var/lib/package/files}
LOG_DIR=${LOG_DIR:-/var/log/package}
SANDBOX_METHOD=${SANDBOX_METHOD:-none} # none|bubblewrap|chroot|container

mkdir -p "$WORKDIR" "$DISTDIR" "$FILES_DIR" "$LOG_DIR"

# Logging fallbacks (if bin/package provides its log_* functions, they'll be used)
: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_error:=:}"
: "${log_event:=:}"

if ! declare -F log_info >/dev/null 2>&1; then
  log_info(){ echo "[build][INFO] $*"; }
fi
if ! declare -F log_warn >/dev/null 2>&1; then
  log_warn(){ echo "[build][WARN] $*"; }
fi
if ! declare -F log_error >/dev/null 2>&1; then
  log_error(){ echo "[build][ERROR] $*" >&2; }
fi
if ! declare -F log_event >/dev/null 2>&1; then
  log_event(){ :; }
fi

# Try to source related modules if present
MODULE_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
[ -f "$MODULE_DIR/fetch.sh" ] && source "$MODULE_DIR/fetch.sh"
[ -f "$MODULE_DIR/patch.sh" ] && source "$MODULE_DIR/patch.sh"
[ -f "$MODULE_DIR/hooks.sh" ] && source "$MODULE_DIR/hooks.sh"
[ -f "$MODULE_DIR/dependency.sh" ] && source "$MODULE_DIR/dependency.sh"
[ -f "$MODULE_DIR/fakeroot.sh" ] && source "$MODULE_DIR/fakeroot.sh"
[ -f "$MODULE_DIR/sandbox.sh" ] && source "$MODULE_DIR/sandbox.sh"
[ -f "$MODULE_DIR/logs.sh" ] && source "$MODULE_DIR/logs.sh"

# Fallbacks for optional functions
if ! declare -F cmd_fetch >/dev/null 2>&1; then
  cmd_fetch(){ log_warn "cmd_fetch não disponível: pulando fetch para $1"; return 0; }
fi
if ! declare -F apply_patches >/dev/null 2>&1; then
  apply_patches(){ log_warn "apply_patches não disponível: pulando patches para $1"; return 0; }
fi
if ! declare -F run_hook >/dev/null 2>&1; then
  run_hook(){ log_info "run_hook não disponível: (port=$1 hook=$2)"; return 0; }
fi
if ! declare -F resolve_dependencies >/dev/null 2>&1; then
  resolve_dependencies(){ log_info "resolve_dependencies não disponível: assumindo deps satisfeitas para $1"; return 0; }
fi
if ! declare -F fakeroot_install_from_staging >/dev/null 2>&1; then
  fakeroot_install_from_staging(){
    local staging="$1" port="$2"
    log_warn "fakeroot_install_from_staging não disponível; fazendo rsync direto (pode requerer sudo)"
    if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
      sudo rsync -a "$staging"/ /
    else
      rsync -a "$staging"/ /
    fi
  }
fi
if ! declare -F sandbox_exec >/dev/null 2>&1; then
  sandbox_exec(){ bash -c "$*"; return $?; }
fi

# Helper: read multiline variable from Makefile
_makefile_var() {
  local mf="$1" var="$2"
  [ -f "$mf" ] || return 1
  # collect lines, handle backslash-continuation
  awk -v v="$var" 'BEGIN{FS=""}
    {line=$0; while(substr(line,length(line),1)=="\\") {getline next; sub(/\\$/,"",line); line=line""next}
    if(line ~ "^[[:space:]]*"v"[[:space:]]*[:=+]"){
      sub("^[[:space:]]*"v"[[:space:]]*[:=+][[:space:]]*","",line);
      gsub(/^[[:space:]]+|[[:space:]]+$/,"",line);
      print line; exit}
  }' "$mf" | sed 's/#.*//' || true
}

_port_key_from_dir(){ local dir="$1" rel="${dir#$PORTSDIR/}" echo "${rel//\//_}" }

_detect_build_system(){ local src="$1" if [ -f "$src/configure" ]; then printf 'autotools' elif [ -f "$src/CMakeLists.txt" ]; then printf 'cmake' elif [ -f "$src/meson.build" ]; then printf 'meson' else printf 'make' fi }

_create_manifest_from_staging(){ local staging="$1" out_manifest="$2" {
  echo "{"
  echo " \"generated_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"," 
  echo " \"staging\":\"$staging\"," 
  echo " \"files\":["
  local first=1
  (cd "$staging" && find . -type f -print0) | while IFS= read -r -d '' f; do
    final="/${f#./}"
    if [ $first -eq 1 ]; then
      printf ' "%s"\n' "$final"
      first=0
    else
      printf ' ,"%s"\n' "$final"
    fi
  done
  echo " ]"
  echo "}"
} > "$out_manifest"
  log_info "Manifest gerado em $out_manifest"
}

# Extract tar intelligently (supports tar.xz, tar.gz, zip)
_extract_archive_to(){ local archive="$1" dest="$2"
  case "$archive" in
    *.tar.gz|*.tgz) tar -xzf "$archive" -C "$dest" ;; 
    *.tar.xz) tar -xJf "$archive" -C "$dest" ;; 
    *.tar.bz2) tar -xjf "$archive" -C "$dest" ;; 
    *.zip) unzip -q "$archive" -d "$dest" ;; 
    *) return 1 ;; 
  esac
}

# Main build implementation
build_port(){
  local port_dir="$1"
  [ -n "$port_dir" ] || { log_error "build_port: port_dir ausente"; return 2; }
  [ -f "$port_dir/Makefile" ] || { log_error "Makefile não encontrado em $port_dir"; return 1; }

  local mf="$port_dir/Makefile"
  local portname portver portkey workdir srcdir builddir staging manifest files_list

  portname=$(_makefile_var "$mf" "PORTNAME")
  portver=$(_makefile_var "$mf" "PORTVERSION")
  [ -z "$portname" ] && portname=$(basename "$port_dir")
  [ -z "$portver" ] && portver=$(_makefile_var "$mf" "VERSION")
  [ -z "$portver" ] && portver="0.0.0"

  portkey=$(_port_key_from_dir "$port_dir")
  workdir="$WORKDIR/$portkey-$portver"
  srcdir="$workdir/src"
  builddir="$workdir/build"
  staging="$workdir/staging"
  manifest="$workdir/${portkey}-${portver}.manifest.json"
  files_list="${FILES_DIR}/${portkey}.list"

  mkdir -p "$workdir" "$srcdir" "$builddir" "$staging" "$(dirname "$files_list")"
  log_info "=== Iniciando build: ${portname} (${portkey}) v${portver} ==="
  log_event "build" "$portkey" "$portver" "start"

  # 0) Resolve deps
  if declare -F resolve_dependencies >/dev/null 2>&1; then
    log_info "Resolvendo dependências para $portkey"
    if ! resolve_dependencies "$port_dir"; then
      log_error "Falha ao resolver dependências para $portkey"
      log_event "build" "$portkey" "$portver" "failed_deps"
      return 1
    fi
  fi

  # 1) Fetch using relative path (category/name) to keep compatibility
  local relpath="${port_dir#$PORTSDIR/}"
  if declare -F cmd_fetch >/dev/null 2>&1; then
    log_info "Executando fetch para $relpath"
    if ! cmd_fetch "$relpath"; then
      log_error "cmd_fetch falhou para $relpath"
      log_event "build" "$portkey" "$portver" "failed_fetch"
      return 1
    fi
  fi

  # 2) Prepare source tree
  log_info "Preparando fontes em $srcdir"
  # try to extract first available distfile
  local distfiles df
  distfiles=$(_makefile_var "$mf" "DISTFILES") || true
  if [ -n "$distfiles" ]; then
    df=$(echo "$distfiles" | awk '{print $1}')
    if [ -f "$DISTDIR/$df" ]; then
      log_info "Extraindo $DISTDIR/$df para $srcdir"
      if ! _extract_archive_to "$DISTDIR/$df" "$srcdir"; then
        log_warn "Extração por formato falhou; tentando tar autodetect"
        (cd "$srcdir" && tar xf "$DISTDIR/$df") || true
      fi
    else
      log_warn "Distfile $df não encontrado em $DISTDIR; usando $port_dir como fonte"
      cp -a "$port_dir/." "$srcdir/"
    fi
  else
    cp -a "$port_dir/." "$srcdir/"
  fi

  # 3) Apply patches
  if declare -F apply_patches >/dev/null 2>&1; then
    log_info "Aplicando patches para $portkey"
    if ! apply_patches "$portkey" "$srcdir"; then
      log_error "Falha ao aplicar patches em $portkey"
      log_event "build" "$portkey" "$portver" "failed_patch"
      return 1
    fi
  fi

  # 4) Detect build system & prepare builddir
  local bsystem
  bsystem=$(_detect_build_system "$srcdir")
  log_info "Build system detectado: $bsystem"
  rm -rf "$builddir"/* || true
  mkdir -p "$builddir"

  # 5) pre-configure hook
  run_hook "$portkey" "pre-configure" || log_warn "pre-configure hook retornou não-zero"

  # 6) Configure
  if [ "$bsystem" = "autotools" ]; then
    log_info "Executando autotools configure em $builddir"
    (cd "$builddir" && env PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:$PKG_CONFIG_PATH" "$srcdir/configure" --prefix="$PREFIX" $CONFIGURE_ARGS) || { log_error "configure falhou"; log_event "build" "$portkey" "$portver" "failed_configure"; return 1; }
  elif [ "$bsystem" = "cmake" ]; then
    log_info "Executando cmake em $builddir"
    (cd "$builddir" && cmake -DCMAKE_INSTALL_PREFIX="$PREFIX" $CONFIGURE_ARGS "$srcdir") || { log_error "cmake falhou"; log_event "build" "$portkey" "$portver" "failed_configure"; return 1; }
  elif [ "$bsystem" = "meson" ]; then
    log_info "Executando meson setup em $builddir"
    (cd "$srcdir" && meson setup "$builddir" --prefix="$PREFIX" $CONFIGURE_ARGS) || { log_error "meson setup falhou"; log_event "build" "$portkey" "$portver" "failed_configure"; return 1; }
  else
    log_info "Nenhuma etapa configure detectada (sistema plain make)"
  fi

  run_hook "$portkey" "post-configure" || log_warn "post-configure hook retornou não-zero"

  # 7) Build
  run_hook "$portkey" "pre-build" || log_warn "pre-build hook retornou não-zero"
  if [ "$bsystem" = "meson" ]; then
    log_info "Compilando (ninja) em $builddir"
    (cd "$builddir" && ninja $MAKEFLAGS) || { log_error "Build (ninja) falhou"; log_event "build" "$portkey" "$portver" "failed_build"; return 1; }
  else
    log_info "Compilando (make) em $builddir"
    (cd "$builddir" && make $MAKEFLAGS) || { log_error "Build (make) falhou"; log_event "build" "$portkey" "$portver" "failed_build"; return 1; }
  fi
  run_hook "$portkey" "post-build" || log_warn "post-build hook retornou não-zero"

  # 8) Tests (make check) if available
  if (cd "$builddir" && make -n check >/dev/null 2>&1); then
    run_hook "$portkey" "pre-check" || true
    log_info "Executando make check em $builddir"
    if ! (cd "$builddir" && make check); then
      log_warn "make check falhou para $portkey (continuando)"
    fi
    run_hook "$portkey" "post-check" || true
  fi

  # 9) Install into staging
  log_info "Instalando em staging: $staging"
  mkdir -p "$staging"
  export DESTDIR="$staging"
  if [ "$bsystem" = "meson" ]; then
    (cd "$builddir" && ninja install DESTDIR="$DESTDIR") || { log_error "ninja install para staging falhou"; log_event "build" "$portkey" "$portver" "failed_install"; return 1; }
  else
    (cd "$builddir" && make install DESTDIR="$DESTDIR") || { log_error "make install falhou"; log_event "build" "$portkey" "$portver" "failed_install"; return 1; }
  fi
  unset DESTDIR

  # 10) Generate files list
  log_info "Gerando lista de arquivos instalados (files list) em $files_list"
  : > "$files_list"
  (cd "$staging" && find . -type f -print0) | while IFS= read -r -d '' f; do
    final="/${f#./}"
    printf '%s\n' "$final"
  done >> "$files_list"

  # manifest
  _create_manifest_from_staging "$staging" "$manifest"

  run_hook "$portkey" "post-install" || true
  log_info "Build concluído com sucesso para $portkey (${portname:-unknown} v${portver}).\nStaging: $staging"
  log_event "build" "$portkey" "$portver" "success"

  # echo staging dir for callers
  echo "$staging"
  return 0
}

# CLI integration
cmd_build(){
  local port="$1"
  [ -n "$port" ] || { log_error "Uso: package build <category/name>"; return 2; }
  local port_dir="$PORTSDIR/$port"
  if [ ! -d "$port_dir" ]; then
    log_error "Port não encontrado: $port_dir"
    return 1
  fi
  build_port "$port_dir"
}

export -f cmd_build build_port

# If executed directly, accept either port dir or category/name
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ $# -lt 1 ]; then
    echo "Uso: $0 <category/name> | <portdir>"
    exit 1
  fi
  if [ -d "$1" ] && [ -f "$1/Makefile" ]; then
    build_port "$1"
  else
    cmd_build "$1"
  fi
fi
