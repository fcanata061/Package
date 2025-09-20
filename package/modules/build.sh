#!/usr/bin/env bash
# build.advanced.sh - versão evoluída e completa do módulo build
# Pipeline: fetch -> verify -> extract -> patch -> configure -> build -> check -> install -> package
# Integra com /etc/package.conf e módulos: fetch.sh, patch.sh, hooks.sh, sandbox.sh, fakeroot.sh, logs.sh
# Exporta: cmd_build build_port

set -euo pipefail
IFS=$'\n\t'

# Carrega config global (se existir)
PKG_CONF=${PKG_CONF:-/etc/package.conf}
[ -f "$PKG_CONF" ] && source "$PKG_CONF"

# Variáveis padrão (caso não venham do package.conf)
PORTSDIR=${PORTSDIR:-/usr/ports}
MODULEDIR=${MODULEDIR:-/opt/package/modules}
CACHE_DIR=${CACHE_DIR:-/var/cache/package}
DISTDIR=${DISTDIR:-${CACHE_DIR}/distfiles}
WORKDIR=${WORKDIR:-${CACHE_DIR}/work}
LOG_DIR=${LOG_DIR:-/var/log/package}
BUILD_LOG_DIR=${BUILD_LOG_DIR:-${LOG_DIR}/builds}
PATCH_LOG_DIR=${PATCH_LOG_DIR:-${LOG_DIR}/patches}
HOOK_LOG_DIR=${HOOK_LOG_DIR:-${LOG_DIR}/hooks}
FILES_DIR=${FILES_DIR:-/var/lib/package/files}
PREFIX=${PREFIX:-/usr/local}
MAKEFLAGS=${MAKEFLAGS:-"-j$(nproc)"}
SANDBOX_METHOD=${SANDBOX_METHOD:-none}
SANDBOX_BASE=${SANDBOX_BASE:-/var/tmp/package-sandbox}
RETAIN_BUILD_DIR=${RETAIN_BUILD_DIR:-no}
CLEAN_WORKDIR_AFTER_BUILD=${CLEAN_WORKDIR_AFTER_BUILD:-yes}
APPLY_PATCHES=${APPLY_PATCHES:-yes}
HOOKS_RUN_MAKEFILE=${HOOKS_RUN_MAKEFILE:-yes}
FAKEROOT_TOOL=${FAKEROOT_TOOL:-tar}
STRICT_CHECK=${STRICT_CHECK:-no}
DRY_RUN=${DRY_RUN:-no}

mkdir -p "$WORKDIR" "$DISTDIR" "$LOG_DIR" "$BUILD_LOG_DIR" "$PATCH_LOG_DIR" "$HOOK_LOG_DIR" "$FILES_DIR"

# Local modules (prefer MODULEDIR then relative modules dir)
MODULE_DIR_CANDIDATES=("${MODULEDIR}" "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/modules" "$(dirname "$(realpath "${BASH_SOURCE[0]}"))/..")
for d in "${MODULE_DIR_CANDIDATES[@]}"; do
  if [ -d "$d" ]; then
    MODULE_DIR="$d"
    break
  fi
done
MODULE_DIR=${MODULE_DIR:-/opt/package/modules}

# Fonte de módulos: tente carregar se existirem
[ -f "$MODULE_DIR/fetch.sh" ] && source "$MODULE_DIR/fetch.sh"
[ -f "$MODULE_DIR/patch.sh" ] && source "$MODULE_DIR/patch.sh"
[ -f "$MODULE_DIR/hooks.sh" ] && source "$MODULE_DIR/hooks.sh"
[ -f "$MODULE_DIR/sandbox.sh" ] && source "$MODULE_DIR/sandbox.sh"
[ -f "$MODULE_DIR/fakeroot.sh" ] && source "$MODULE_DIR/fakeroot.sh"
[ -f "$MODULE_DIR/logs.sh" ] && source "$MODULE_DIR/logs.sh"

# logging minimal
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

# Fallbacks para funções de módulo
: ${cmd_fetch:=:}
: ${apply_patches:=:}
: ${run_hook:=:}
: ${sandbox_exec:=:}
: ${fakeroot_install_from_staging:=:}

# util: lê variável do Makefile similar a _makefile_var mas preserva valores com espaços
_read_makefile_var(){
  local mf="$1" var="$2"
  [ -f "$mf" ] || return 1
  awk -v v="$var" '
    $0 ~ "^[[:space:]]*"v"[[:space:]]*=" {
      sub("^[[:space:]]*"v"[[:space:]]*=" , "")
      val=$0
      while (val ~ /\\$/) {
        sub(/\\$/,"",val)
        if (getline nx) val = val nx
        else break
      }
      # strip comment
      sub(/#.*$/,"",val)
      gsub(/^[[:space:]]+/,"",val)
      gsub(/[[:space:]]+$/,"",val)
      print val
      exit
    }
  ' "$mf"
}

# detect build system
_detect_build_system(){
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

# phases in order
PHASES=(fetch verify extract patch configure build check install package)

_phase_index(){ local ph="$1"; for i in "${!PHASES[@]}"; do [ "${PHASES[$i]}" = "$ph" ] && echo $i && return 0; done; return 1; }

# run command in sandbox if available, log to file
_run_phase_cmd(){
  local phase="$1" cmd="$2" workdir="$3" logfile="$4"
  log_info "[phase:$phase] CMD: $cmd"
  if [ "$DRY_RUN" = "yes" ]; then
    log_info "DRY_RUN=yes -> não executando comando"
    return 0
  fi
  mkdir -p "$(dirname "$logfile")"
  if declare -F sandbox_exec >/dev/null 2>&1 && [ "$SANDBOX_METHOD" != "none" ]; then
    # sandbox_exec expected to accept command as a single string
    sandbox_exec "$cmd" >>"$logfile" 2>&1 || return $?
  else
    (cd "$workdir" && bash -lc "$cmd") >>"$logfile" 2>&1 || return $?
  fi
}

# high-level build_port implementation
build_port(){
  local portdir="$1"
  local resume_from="${2:-}"
  if [ -z "$portdir" ]; then log_error "build_port: portdir faltando"; return 2; fi
  if [ ! -d "$portdir" ] || [ ! -f "$portdir/Makefile" ]; then log_error "Port inválido ou Makefile ausente: $portdir"; return 1; fi

  # read Makefile vars
  local mf="$portdir/Makefile"
  local SRC_URL PATCHES CONFIGURE_OPTS BUILD_OPTS INSTALL_OPTS PORTNAME PORTVERSION PORTKEY
  SRC_URL=$(_read_makefile_var "$mf" "SRC_URL") || true
  PATCHES=$(_read_makefile_var "$mf" "PATCHES") || true
  CONFIGURE_OPTS=$(_read_makefile_var "$mf" "CONFIGURE_OPTS") || true
  BUILD_OPTS=$(_read_makefile_var "$mf" "BUILD_OPTS") || true
  INSTALL_OPTS=$(_read_makefile_var "$mf" "INSTALL_OPTS") || true
  PORTNAME=$(_read_makefile_var "$mf" "PORTNAME") || true
  PORTVERSION=$(_read_makefile_var "$mf" "PORTVERSION") || true
  if [ -z "$PORTNAME" ]; then PORTNAME=$(basename "$portdir"); fi
  if [ -z "$PORTVERSION" ]; then PORTVERSION="0.0.0"; fi
  PORTKEY=${PORTKEY:-$(echo "${portdir#$PORTSDIR/}" | tr '/' '_')}

  local workdir="$WORKDIR/${PORTKEY}-${PORTVERSION}"
  local srcdir="$workdir/src"
  local builddir="$workdir/build"
  local staging="$workdir/staging"
  local manifest="$workdir/${PORTKEY}-${PORTVERSION}.manifest.json"
  mkdir -p "$workdir" "$srcdir" "$builddir" "$staging"

  log_info "=== BUILD START: $PORTNAME ($PORTKEY) v$PORTVERSION ==="
  log_event "build" "$PORTKEY" "$PORTVERSION" "start" || true

  # determine resume index
  local start_idx=0
  if [ -n "$resume_from" ]; then
    if idx=$(_phase_index "$resume_from"); then start_idx=$idx; fi
  fi

  # helper to run phase with hooks and logs
  _run_phase(){
    local phase="$1"; shift
    if idx=$(_phase_index "$phase"); then true; else log_error "Fase desconhecida: $phase"; return 2; fi
    if [ $idx -lt $start_idx ]; then log_info "Pulando fase $phase (antes do ponto de resume)"; return 0; fi

    local phase_log="$BUILD_LOG_DIR/${PORTKEY}-${PORTVERSION}-${phase}.log"

    # pre-hook
    run_hook "$portdir" "pre-$phase" || log_warn "pre-$phase hook retornou não-zero"

    # executar ação por fase
    case "$phase" in
      fetch)
        if [ -z "$SRC_URL" ]; then
          # tentar extrair DISTFILES da Makefile (compat com ports)
          local df=$(grep -E "^DISTFILES" "$mf" | head -n1 | cut -d'=' -f2- | sed 's/#.*//') || true
          if [ -n "$df" ]; then
            df=$(echo "$df" | awk '{print $1}' | xargs)
            if [ -f "$DISTDIR/$df" ]; then
              log_info "Usando distfile local: $DISTDIR/$df"
              cp -a "$DISTDIR/$df" "$workdir/" || true
            else
              log_info "Nenhum SRC_URL nem DISTFILES válido encontrado, copiando porta para srcdir"
              cp -a "$portdir/." "$srcdir/"
            fi
          else
            cp -a "$portdir/." "$srcdir/"
          fi
        else
          if declare -F fetch_source >/dev/null 2>&1; then
            fetch_source "$SRC_URL" "$srcdir" || return 1
          else
            log_error "fetch_source não disponível; não é possível obter fontes"; return 1
          fi
        fi
        ;;
      verify)
        # verify: checar distinfo SHA256 se disponível
        if [ -f "$portdir/distinfo" ]; then
          log_info "Verificando checksums em distinfo"
          # distinfo formato simples: SHA256 filename
          if ! (cd "$srcdir" && awk '{print $1"  "substr($0,index($0,$2))}' "$portdir/distinfo" | sha256sum -c - >/dev/null 2>&1); then
            log_error "Verificação de checksums falhou"; return 1
          fi
        else
          log_info "Sem distinfo; pulando verificação";
        fi
        ;;
      extract)
        # se já foi baixado e extraído pelo fetch_source, pule; caso contrário tente extrair distfile do workdir
        if [ -n "$(ls -A "$srcdir" 2>/dev/null || true)" ]; then
          log_info "srcdir já tem arquivos; pulando extract"
        else
          # procurar arquivo em workdir
          local df=$(ls -1 "$workdir"/* 2>/dev/null | head -n1 || true)
          if [ -n "$df" ]; then
            case "$df" in
              *.tar.gz|*.tgz) tar -xzf "$df" -C "$srcdir" --strip-components=1 ;; 
              *.tar.bz2|*.tbz2) tar -xjf "$df" -C "$srcdir" --strip-components=1 ;; 
              *.tar.xz|*.txz) tar -xJf "$df" -C "$srcdir" --strip-components=1 ;; 
              *.zip) unzip -q "$df" -d "$srcdir" ;;
              *) cp -a "$df" "$srcdir/" ;;
            esac
          else
            log_warn "Nenhum distfile para extrair e srcdir vazio"
          fi
        fi
        ;;
      patch)
        if [ "$APPLY_PATCHES" != "yes" ]; then log_info "APPLY_PATCHES != yes -> pulando patches"; return 0; fi
        if [ -n "$PATCHES" ]; then
          if declare -F apply_patches >/dev/null 2>&1; then
            apply_patches "$portdir" "$srcdir" >>"$PATCH_LOG_DIR/${PORTKEY}-${PORTVERSION}-patches.log" 2>&1 || { log_error "apply_patches falhou"; return 1; }
          else
            log_warn "apply_patches não implementado; pulando"
          fi
        else
          # procurar patches em portdir/patches
          if [ -d "$portdir/patches" ]; then
            if declare -F apply_patches >/dev/null 2>&1; then
              apply_patches "$portdir" "$srcdir" >>"$PATCH_LOG_DIR/${PORTKEY}-${PORTVERSION}-patches.log" 2>&1 || { log_error "apply_patches falhou"; return 1; }
            else
              log_warn "apply_patches não implementado; pulando"
            fi
          else
            log_info "Nenhum patch encontrado; pulando"
          fi
        fi
        ;;
      configure)
        run_hook "$portdir" "pre-configure" || true
        local bsys=$(_detect_build_system "$srcdir")
        log_info "Sistema de build: $bsys"
        case "$bsys" in
          autotools)
            _run_phase_cmd "configure" "(cd $builddir && $srcdir/configure --prefix=$PREFIX $CONFIGURE_OPTS)" "$workdir" "$phase_log" || { log_error "configure falhou"; return 1; }
            ;;
          cmake)
            _run_phase_cmd "configure" "(cd $builddir && cmake -DCMAKE_INSTALL_PREFIX=$PREFIX $CONFIGURE_OPTS $srcdir)" "$workdir" "$phase_log" || { log_error "cmake falhou"; return 1; }
            ;;
          meson)
            _run_phase_cmd "configure" "meson setup $builddir --prefix=$PREFIX $CONFIGURE_OPTS $srcdir" "$workdir" "$phase_log" || { log_error "meson setup falhou"; return 1; }
            ;;
          *)
            log_info "Sem etapa configure para make puro"
            ;;
        esac
        run_hook "$portdir" "post-configure" || true
        ;;
      build)
        run_hook "$portdir" "pre-build" || true
        local bsys2=$(_detect_build_system "$srcdir")
        case "$bsys2" in
          meson)
            _run_phase_cmd "build" "(cd $builddir && ninja $MAKEFLAGS $BUILD_OPTS)" "$workdir" "$phase_log" || { log_error "build falhou"; return 1; }
            ;;
          cmake)
            _run_phase_cmd "build" "(cd $builddir && cmake --build . -- -j$(nproc) $BUILD_OPTS)" "$workdir" "$phase_log" || { log_error "build falhou"; return 1; }
            ;;
          *)
            _run_phase_cmd "build" "(cd $builddir && make $MAKEFLAGS $BUILD_OPTS)" "$workdir" "$phase_log" || { log_error "make falhou"; return 1; }
            ;;
        esac
        run_hook "$portdir" "post-build" || true
        ;;
      check)
        if (cd "$builddir" && eval "$MAKE_CHECK_CMD" >/dev/null 2>&1); then
          run_hook "$portdir" "pre-check" || true
          _run_phase_cmd "check" "(cd $builddir && $MAKE_CHECK_CMD)" "$workdir" "$phase_log" || {
            log_warn "Testes falharam; verifique $phase_log"
            if [ "$STRICT_CHECK" = "yes" ]; then return 1; fi
          }
          run_hook "$portdir" "post-check" || true
        else
          log_info "Target de check não detectado; pulando"
        fi
        ;;
      install)
        run_hook "$portdir" "pre-install" || true
        mkdir -p "$staging"
        export DESTDIR="$staging"
        local bsys3=$(_detect_build_system "$srcdir")
        case "$bsys3" in
          meson)
            _run_phase_cmd "install" "(cd $builddir && ninja install DESTDIR=$DESTDIR)" "$workdir" "$phase_log" || { log_error "install falhou"; return 1; }
            ;;
          cmake)
            _run_phase_cmd "install" "(cd $builddir && cmake --install . --prefix=$PREFIX --destdir=$DESTDIR)" "$workdir" "$phase_log" || { log_error "install falhou"; return 1; }
            ;;
          *)
            _run_phase_cmd "install" "(cd $builddir && make DESTDIR=$DESTDIR install $INSTALL_OPTS)" "$workdir" "$phase_log" || { log_error "install falhou"; return 1; }
            ;;
        esac
        unset DESTDIR
        run_hook "$portdir" "post-install" || true
        ;;
      package)
        run_hook "$portdir" "pre-package" || true
        # gerar lista de arquivos
        : > "$FILES_DIR/${PORTKEY}.list"
        (cd "$staging" && find . -type f -print0 | while IFS= read -r -d '' f; do printf "/%s\n" "${f#./}"; done) >> "$FILES_DIR/${PORTKEY}.list"
        # gerar manifest
        (cd "$staging" && tar -czpf "$workdir/${PORTKEY}-${PORTVERSION}.tar.gz" .) || { log_error "Falha ao gerar tar.gz"; return 1; }
        if declare -F fakeroot_install_from_staging >/dev/null 2>&1; then
          fakeroot_install_from_staging "$staging" "$PORTKEY" >>"$BUILD_LOG_DIR/${PORTKEY}-${PORTVERSION}-package.log" 2>&1 || { log_error "fakeroot_install falhou"; return 1; }
        fi
        _create_manifest_from_staging "$staging" "$manifest" || true
        run_hook "$portdir" "post-package" || true
        ;;
      *)
        log_warn "Fase não implementada: $phase"; return 2
        ;;
    esac

    log_info "[phase:$phase] concluída. log: $phase_log"
    run_hook "$portdir" "after-$phase" || true
    return 0
  }

  # iterate phases
  local i
  for i in "${PHASES[@]}"; do
    _run_phase "$i" || { log_error "Fase $i falhou. Ver logs em $BUILD_LOG_DIR"; log_event "build" "$PORTKEY" "$PORTVERSION" "failed_$i" || true; return 1; }
  done

  log_info "=== BUILD SUCCESS: $PORTNAME ($PORTKEY) v$PORTVERSION ==="
  log_event "build" "$PORTKEY" "$PORTVERSION" "success" || true

  # cleanup
  if [ "$CLEAN_WORKDIR_AFTER_BUILD" = "yes" ] && [ "$RETAIN_BUILD_DIR" != "yes" ]; then
    rm -rf "$workdir" || true
  fi

  # return path to generated package or staging
  if [ -f "$workdir/${PORTKEY}-${PORTVERSION}.tar.gz" ]; then
    echo "$workdir/${PORTKEY}-${PORTVERSION}.tar.gz"
  else
    echo "$staging"
  fi
}

# CLI wrapper: cmd_build <portkey|/path/to/port> [--resume <phase>]
cmd_build(){
  if [ $# -lt 1 ]; then echo "Uso: cmd_build <categoria/port|/caminho/portdir> [--resume <phase>]"; return 2; fi
  local arg="$1"; shift
  local resume=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --resume) resume="$2"; shift 2 ;;
      --dry-run) DRY_RUN=yes; shift ;;
      *) shift ;;
    esac
  done
  local portdir
  if [ -d "$arg" ] && [ -f "$arg/Makefile" ]; then portdir="$arg"; else portdir="$PORTSDIR/$arg"; fi
  build_port "$portdir" "$resume"
}

export -f build_port cmd_build

# se executado diretamente
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  cmd_build "$@"
fi
