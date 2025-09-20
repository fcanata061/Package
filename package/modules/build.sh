#!/usr/bin/env bash
# modules/build.sh
# cmd_build <categoria/port>
# - detecta sistema de build (autotools, cmake, meson, simple Makefile)
# - roda configure/build
# - respeita DESTDIR (instalação em staging)
# - integra com fetch, patch, hooks, config

set -euo pipefail

[ -f /etc/package.conf ] && source /etc/package.conf

# defaults
PORTSDIR=${PORTSDIR:-/usr/ports}
WORKDIR=${WORKDIR:-/var/cache/package/work}
DISTDIR=${DISTDIR:-/var/cache/package/distfiles}
MAKEFLAGS=${MAKEFLAGS:-"-j$(nproc)"}
BUILD_CMD=${BUILD_CMD:-make}
MAKE_CHECK_CMD=${MAKE_CHECK_CMD:-"make check"}
HOOKS_RUN_MAKEFILE=${HOOKS_RUN_MAKEFILE:-yes}

FILES_DIR=${FILES_DIR:-/var/lib/package/files}
mkdir -p "$WORKDIR" "$DISTDIR" "$FILES_DIR"

# logging fallbacks
: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_error:=:}"
if ! declare -F log_info >/dev/null; then log_info(){ echo "[build][INFO] $*"; }; fi
if ! declare -F log_warn >/dev/null; then log_warn(){ echo "[build][WARN] $*"; }; fi
if ! declare -F log_error >/dev/null; then log_error(){ echo "[build][ERROR] $*" >&2; }; fi
: "${run_hook:=:}"
if ! declare -F run_hook >/dev/null; then run_hook(){ log_info "Hook runner não implementado: $*"; return 0; }; fi
: "${cmd_fetch:=:}"
if ! declare -F cmd_fetch >/dev/null; then cmd_fetch(){ log_warn "cmd_fetch não implementado; assegure que fontes existem"; return 0; }; fi
: "${patch_apply:=:}"
# fallback patch_apply exists? if not, ignore
if ! declare -F patch_apply >/dev/null; then
  patch_apply(){ log_warn "patch_apply não implementado; pulando patches"; return 0; }
fi

_run_as_root(){
  # run command as root, using sudo if not already root
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    if command -v sudo >/dev/null 2>&1; then
      sudo "$@"
    else
      log_error "É necessário root (ou sudo) para executar: $*"
      return 1
    fi
  fi
}

# read variable from port Makefile (supports line continuation)
_makefile_var() {
  local mf="$1" var="$2"
  [ -f "$mf" ] || return 1
  awk -v v="$var" '
    $0 ~ "^[[:space:]]*"v"[[:space:]]*=" {
      sub("^[[:space:]]*"v"[[:space:]]*=","")
      val=$0;
      while (val ~ /\\$/) { sub(/\\$/,"",val); if (getline nx) val = val nx; else break; }
      gsub(/^[[:space:]]+/,"",val); gsub(/[[:space:]]+$/,"",val);
      print val;
    }' "$mf" | sed 's/#.*//' | xargs || true
}

_detect_build_system() {
  local src="$1"
  if [ -f "$src/configure" ]; then
    printf 'autotools'
  elif [ -f "$src/CMakeLists.txt" ]; then
    printf 'cmake'
  elif [ -f "$src/meson.build" ]; then
    printf 'meson'
  else
    printf 'make'
  fi
}

# configure args from Makefile (CONFIGURE_ARGS) or empty
_get_configure_args() {
  local mf="$1"
  _makefile_var "$mf" "CONFIGURE_ARGS"
}

# ENTRYPOINT
cmd_build() {
  local port="$1"
  [ -n "$port" ] || { log_error "Uso: package build <categoria/port>"; return 2; }

  local mf="$PORTSDIR/$port/Makefile"
  if [ ! -f "$mf" ]; then log_error "Makefile não encontrado para $port ($mf)"; return 1; fi

  # prepare workdir for this port
  local portname portwork wrksrc builddir
  portname=$(echo "$port" | tr '/' '_')
  portwork="$WORKDIR/$portname"
  mkdir -p "$portwork"
  # ensure sources present: call cmd_fetch if available
  log_info "Garantindo fontes para $port (fetch)"
  if declare -F cmd_fetch >/dev/null; then
    cmd_fetch "$port" || {
      log_warn "cmd_fetch falhou ou não trouxe arquivos; continuando (talvez fontes já estejam presentes)"
    }
  fi

  # detect extracted source directory under WORKDIR or PORTSDIR/<port>
  # prefer PORTSDIR/$port/work or default to PORTSDIR/$port
  local srcdir
  if [ -d "$PORTSDIR/$port" ]; then
    srcdir="$PORTSDIR/$port"
  else
    srcdir="$portwork"
  fi

  # apply patches (if any)
  log_info "Aplicando patches para $port (se existirem)"
  patch_apply "$port" "$srcdir" || { log_warn "Falha ao aplicar patches para $port"; }

  # hooks pre-build (Makefile target or hooks script)
  run_hook "$port" "pre-build" || log_warn "hook pre-build retornou não-zero (continuando)"

  # detect build system
  builddir="$srcdir"
  local bs; bs=$(_detect_build_system "$srcdir")
  log_info "Build system detectado: $bs"

  # If autotools or cmake, create a separate build dir (out-of-source)
  if [ "$bs" = "autotools" ] || [ "$bs" = "cmake" ] || [ "$bs" = "meson" ]; then
    builddir="${srcdir}/build"
    mkdir -p "$builddir"
  fi

  # configure step
  local configure_args
  configure_args=$(_get_configure_args "$mf")
  if [ "$bs" = "autotools" ]; then
    log_info "Executando configure em $builddir"
    (cd "$builddir" && env PKG_CONFIG_PATH="${PREFIX:-/usr/local}/lib/pkgconfig:$PKG_CONFIG_PATH" "$srcdir/configure" ${configure_args} --prefix="${PREFIX:-/usr/local}") || { log_error "configure falhou"; return 1; }
  elif [ "$bs" = "cmake" ]; then
    log_info "Executando cmake em $builddir"
    (cd "$builddir" && cmake -DCMAKE_INSTALL_PREFIX="${PREFIX:-/usr/local}" $configure_args "$srcdir") || { log_error "cmake falhou"; return 1; }
  elif [ "$bs" = "meson" ]; then
    log_info "Configurando meson em $builddir"
    (cd "$srcdir" && meson setup "$builddir" --prefix="${PREFIX:-/usr/local}" $configure_args) || { log_error "meson setup falhou"; return 1; }
  else
    log_info "Sistema make simples; pulando etapa configure"
  fi

  # build step
  log_info "Compilando $port (makeflags='$MAKEFLAGS') em $builddir"
  if [ "$bs" = "meson" ]; then
    (cd "$builddir" && ninja $MAKEFLAGS) || { log_error "Falha no build (meson/ninja)"; return 1; }
  else
    (cd "$builddir" && $BUILD_CMD $MAKEFLAGS) || { log_error "Falha no build (make)"; return 1; }
  fi

  # run tests if exist
  if [ "$HOOKS_RUN_MAKEFILE" = "yes" ]; then
    if (cd "$builddir" && $MAKE_CHECK_CMD >/dev/null 2>&1); then
      log_info "make check disponível e executado (se passou, ótimo)"
    else
      log_info "make check não disponível ou falhou — continue se desejado"
    fi
  fi

  # If DESTDIR is set, attempt to install into it
  if [ -n "${DESTDIR:-}" ]; then
    log_info "DESTDIR detectado; instalando em staging: $DESTDIR"
    mkdir -p "$DESTDIR"
    if [ "$bs" = "meson" ]; then
      (cd "$builddir" && ninja install DESTDIR="$DESTDIR") || { log_error "ninja install falhou"; return 1; }
    elif [ "$bs" = "cmake" ]; then
      (cd "$builddir" && $BUILD_CMD install DESTDIR="$DESTDIR") || { log_error "cmake make install falhou"; return 1; }
    else
      (cd "$builddir" && $BUILD_CMD install DESTDIR="$DESTDIR") || { log_error "make install falhou"; return 1; }
    fi
    log_info "Instalação em staging concluída: $DESTDIR"
  else
    log_info "DESTDIR não presente — operação de instalação deve ser feita por cmd_install"
  fi

  # hooks post-build
  run_hook "$port" "post-build" || log_warn "hook post-build retornou não-zero (continuando)"

  return 0
}

export -f cmd_build
