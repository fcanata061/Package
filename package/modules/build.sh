#!/usr/bin/env bash
# build.sh - módulo evoluído e funcional para gerenciador de pacotes
# Objetivo: construir um "port" (diretório com Makefile) em sandbox, executar hooks,
# instalar em staging com DESTDIR e fornecer staging path como saída.
# Exporta as funções: cmd_build, build_port

set -euo pipefail
IFS=$'\n\t'

### Configuráveis por ambiente ou /etc/package.conf
PORTSDIR=${PORTSDIR:-/usr/ports}
WORKDIR=${WORKDIR:-/var/cache/package/work}
DISTDIR=${DISTDIR:-/var/cache/package/distfiles}
PREFIX=${PREFIX:-/usr/local}
MAKEFLAGS=${MAKEFLAGS:-"-j$(nproc)"}
CONFIGURE_ARGS=${CONFIGURE_ARGS:-""}
LOG_DIR=${LOG_DIR:-/var/log/package}
FILES_DIR=${FILES_DIR:-/var/lib/package/files}
SANDBOX_METHOD=${SANDBOX_METHOD:-none}    # none|bubblewrap|chroot|container
STRICT_CHECK=${STRICT_CHECK:-no}          # yes|no
HOOKS_RUN_MAKEFILE=${HOOKS_RUN_MAKEFILE:-yes}

# Cria diretórios necessários
mkdir -p "$WORKDIR" "$DISTDIR" "$FILES_DIR" "$LOG_DIR"

### Logging simples caso não haja módulo externo
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

### Carrega módulos auxiliares se existirem (fetch, patch, hooks, dependency, fakeroot, sandbox, logs)
MODULE_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
[ -f "$MODULE_DIR/fetch.sh" ]     && source "$MODULE_DIR/fetch.sh"
[ -f "$MODULE_DIR/patch.sh" ]     && source "$MODULE_DIR/patch.sh"
[ -f "$MODULE_DIR/hooks.sh" ]     && source "$MODULE_DIR/hooks.sh"
[ -f "$MODULE_DIR/dependency.sh" ] && source "$MODULE_DIR/dependency.sh"
[ -f "$MODULE_DIR/fakeroot.sh" ]  && source "$MODULE_DIR/fakeroot.sh"
[ -f "$MODULE_DIR/sandbox.sh" ]   && source "$MODULE_DIR/sandbox.sh"
[ -f "$MODULE_DIR/logs.sh" ]      && source "$MODULE_DIR/logs.sh"

# Fallbacks para funções esperadas de módulos
if ! declare -F cmd_fetch >/dev/null 2>&1; then
  cmd_fetch(){ log_warn "cmd_fetch não implementado: pulando fetch para $1"; return 0; }
fi
if ! declare -F apply_patches >/dev/null 2>&1; then
  apply_patches(){ log_warn "apply_patches não implementado: pulando patches para $1"; return 0; }
fi
if ! declare -F run_hook >/dev/null 2>&1; then
  # run_hook PORTKEY HOOKNAME [ARGS...]
  run_hook(){ log_info "(hook faltando) \$1:\$2"; return 0; }
fi
if ! declare -F resolve_dependencies >/dev/null 2>&1; then
  resolve_dependencies(){ log_info "(resolver deps faltando) assumindo deps satisfeitas para $1"; return 0; }
fi
if ! declare -F fakeroot_install_from_staging >/dev/null 2>&1; then
  fakeroot_install_from_staging(){
    local staging="$1" portkey="$2"
    log_warn "fakeroot_install_from_staging não implementado: usando rsync direto (pode requerer sudo)"
    if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
      sudo rsync -a "$staging"/ /
    else
      rsync -a "$staging"/ /
    fi
  }
fi
if ! declare -F sandbox_exec >/dev/null 2>&1; then
  sandbox_exec(){ # simplesmente executa o comando diretamente
    bash -c "$*"
  }
fi

### Utilitários internos
_makefile_var(){
  # _makefile_var MAKEFILE VAR -> retorna valor (primeira palavra) ou vazio
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
      gsub(/^[[:space:]]+/,"",val)
      gsub(/[[:space:]]+$/,"",val)
      print val
      exit
    }
  ' "$mf" | sed 's/#.*//' | xargs 2>/dev/null || true
}

_port_key_from_dir(){
  local dir="$1"
  local rel="${dir#$PORTSDIR/}"
  echo "${rel//\//_}"
}

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

_create_manifest_from_staging(){
  local staging="$1" out_manifest="$2"
  {
    echo "{"
    echo "  \"generated_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"," 
    echo "  \"staging\":\"$staging\"," 
    echo "  \"files\":["
    local first=1
    (cd "$staging" && find . -type f -print0 | while IFS= read -r -d '' f; do
      local final="/${f#./}"
      if [ $first -eq 1 ]; then
        printf "    \"%s\"\n" "$final"
        first=0
      else
        printf "   , \"%s\"\n" "$final"
      fi
    done)
    echo "  ]"
    echo "}"
  } > "$out_manifest"
  log_info "Manifest gerado em $out_manifest"
}

_run_in_sandbox_or_direct(){
  local cmd_descr="$1"; shift
  if [ "$SANDBOX_METHOD" != "none" ]; then
    log_info "[$cmd_descr] executando em sandbox ($SANDBOX_METHOD): $*"
    sandbox_exec "$*"
  else
    log_info "[$cmd_descr] executando diretamente: $*"
    bash -c "$*"
  fi
}

### Função principal: build de um port (diretório com Makefile)
build_port(){
  local port_dir="$1"
  if [ -z "$port_dir" ]; then
    log_error "build_port: port_dir ausente"
    return 2
  fi
  if [ ! -f "$port_dir/Makefile" ]; then
    log_error "Makefile não encontrado em $port_dir"
    return 1
  fi

  local mf portname portver portkey workdir srcdir builddir staging manifest files_list distfiles df bsystem

  mf="$port_dir/Makefile"
  portname=$(_makefile_var "$mf" "PORTNAME")
  portver=$(_makefile_var "$mf" "PORTVERSION")
  [ -z "$portname" ] && portname=$(basename "$port_dir")
  [ -z "$portver" ] && portver=$(_makefile_var "$mf" "VERSION")
  [ -z "$portver" ] && portver="0.0.0"

  portkey=$(_port_key_from_dir "$port_dir")
  workdir="$WORKDIR/${portkey}-${portver}"
  srcdir="$workdir/src"
  builddir="$workdir/build"
  staging="$workdir/staging"
  manifest="$workdir/${portkey}-${portver}.manifest.json"
  files_list="${FILES_DIR}/${portkey}.list"

  mkdir -p "$workdir" "$srcdir" "$builddir" "$staging" "$(dirname "$files_list")"

  log_info "=== Iniciando build: $portname ($portkey) v$portver ==="
  log_event "build" "$portkey" "$portver" "start" || true

  # 0) Dependências
  if declare -F resolve_dependencies >/dev/null 2>&1; then
    log_info "Resolvendo dependências para $portkey"
    if ! resolve_dependencies "$port_dir"; then
      log_error "Falha ao resolver dependências para $portkey"
      log_event "build" "$portkey" "$portver" "failed_deps" || true
      return 1
    fi
  fi

  # 1) Fetch
  if declare -F cmd_fetch >/dev/null 2>&1; then
    log_info "Executando fetch para $portkey"
    if ! cmd_fetch "$portkey"; then
      log_error "cmd_fetch falhou para $portkey"
      log_event "build" "$portkey" "$portver" "failed_fetch" || true
      return 1
    fi
  fi

  # 2) Preparar fontes
  log_info "Preparando fontes em $srcdir"
  distfiles=$(_makefile_var "$mf" "DISTFILES")
  if [ -n "$distfiles" ]; then
    df=$(echo "$distfiles" | awk '{print $1}')
    if [ -f "$DISTDIR/$df" ]; then
      log_info "Extraindo $DISTDIR/$df para $srcdir"
      (cd "$srcdir" && tar xf "$DISTDIR/$df") || { log_error "Falha ao extrair $df"; return 1; }
    else
      log_warn "Distfile $df não encontrado em $DISTDIR; copiando porta para srcdir"
      cp -a "$port_dir/." "$srcdir/"
    fi
  else
    cp -a "$port_dir/." "$srcdir/"
  fi

  # 3) Aplicar patches
  if declare -F apply_patches >/dev/null 2>&1; then
    log_info "Aplicando patches para $portkey"
    if ! apply_patches "$portkey" "$srcdir"; then
      log_error "Falha ao aplicar patches em $portkey"
      log_event "build" "$portkey" "$portver" "failed_patches" || true
      return 1
    fi
  fi

  # 4) Detectar sistema de build
  bsystem=$(_detect_build_system "$srcdir")
  log_info "Sistema de build detectado: $bsystem"

  # 5) Limpar builddir
  rm -rf "$builddir"
  mkdir -p "$builddir"

  # Hook: pre-configure
  run_hook "$portkey" "pre-configure" || log_warn "pre-configure hook retornou não-zero"

  # 6) Configurar
  local log_cf="$LOG_DIR/${portkey}-${portver}-configure.log"
  case "$bsystem" in
    autotools)
      log_info "Executando autotools configure"
      (cd "$builddir" && _run_in_sandbox_or_direct "configure" "$srcdir/configure --prefix=$PREFIX $CONFIGURE_ARGS") >"$log_cf" 2>&1 || {
        log_error "Falha na configure. Veja $log_cf"; log_event "build" "$portkey" "$portver" "failed_configure" || true; return 1
      }
      ;;
    cmake)
      log_info "Executando cmake"
      (cd "$builddir" && _run_in_sandbox_or_direct "configure" "cmake -DCMAKE_INSTALL_PREFIX=$PREFIX $CONFIGURE_ARGS $srcdir") >"$log_cf" 2>&1 || {
        log_error "Falha no cmake. Veja $log_cf"; log_event "build" "$portkey" "$portver" "failed_configure" || true; return 1
      }
      ;;
    meson)
      log_info "Executando meson setup"
      _run_in_sandbox_or_direct "configure" "meson setup $builddir --prefix=$PREFIX $CONFIGURE_ARGS $srcdir" >"$log_cf" 2>&1 || {
        log_error "Falha no meson setup. Veja $log_cf"; log_event "build" "$portkey" "$portver" "failed_configure" || true; return 1
      }
      ;;
    *)
      log_info "Sem etapa configure para sistema plain make"
      ;;
  esac
  run_hook "$portkey" "post-configure" || log_warn "post-configure hook não-zero"

  # 7) Build
  run_hook "$portkey" "pre-build" || log_warn "pre-build hook não-zero"
  local log_bu="$LOG_DIR/${portkey}-${portver}-build.log"
  case "$bsystem" in
    meson)
      log_info "Construindo com ninja"
      (cd "$builddir" && _run_in_sandbox_or_direct "build" "ninja $MAKEFLAGS") >"$log_bu" 2>&1 || { log_error "Falha no build. Veja $log_bu"; log_event "build" "$portkey" "$portver" "failed_build" || true; return 1; }
      ;;
    *)
      log_info "Construindo com make"
      (cd "$builddir" && _run_in_sandbox_or_direct "build" "make $MAKEFLAGS") >"$log_bu" 2>&1 || { log_error "Falha no build. Veja $log_bu"; log_event "build" "$portkey" "$portver" "failed_build" || true; return 1; }
      ;;
  esac
  run_hook "$portkey" "post-build" || log_warn "post-build hook não-zero"

  # 8) Check/testes
  local test_log="$LOG_DIR/${portkey}-${portver}-check.log"
  if (cd "$builddir" && make -n check >/dev/null 2>&1); then
    run_hook "$portkey" "pre-check" || true
    log_info "Executando make check para $portkey"
    (cd "$builddir" && _run_in_sandbox_or_direct "check" "make check") >"$test_log" 2>&1 || {
      log_warn "make check falhou para $portkey; verifique $test_log"
      if [ "$STRICT_CHECK" = "yes" ]; then
        log_event "build" "$portkey" "$portver" "failed_check" || true
        return 1
      fi
    }
    run_hook "$portkey" "post-check" || true
  else
    log_info "Não há target 'check' presente ou não executável; pulando testes"
  fi

  # 9) Instalar em staging (DESTDIR)
  log_info "Instalando em staging: $staging"
  mkdir -p "$staging"
  export DESTDIR="$staging"
  local log_inst="$LOG_DIR/${portkey}-${portver}-install.log"
  case "$bsystem" in
    meson)
      (cd "$builddir" && _run_in_sandbox_or_direct "install" "ninja install DESTDIR=$DESTDIR") >"$log_inst" 2>&1 || { log_error "Falha na instalação (staging). Veja $log_inst"; log_event "build" "$portkey" "$portver" "failed_install" || true; return 1; }
      ;;
    cmake)
      (cd "$builddir" && _run_in_sandbox_or_direct "install" "cmake --install . --prefix=$PREFIX --destdir=$DESTDIR") >"$log_inst" 2>&1 || { log_error "Falha na instalação (staging). Veja $log_inst"; log_event "build" "$portkey" "$portver" "failed_install" || true; return 1; }
      ;;
    *)
      (cd "$builddir" && _run_in_sandbox_or_direct "install" "make install DESTDIR=$DESTDIR") >"$log_inst" 2>&1 || { log_error "Falha na instalação (staging). Veja $log_inst"; log_event "build" "$portkey" "$portver" "failed_install" || true; return 1; }
      ;;
  esac
  unset DESTDIR

  # 10) Gerar lista de arquivos e manifest
  log_info "Gerando lista de arquivos instalados em $files_list"
  : > "$files_list"
  (cd "$staging" && find . -type f -print0 | while IFS= read -r -d '' f; do
    printf "/%s\n" "${f#./}"
  done) >> "$files_list"

  _create_manifest_from_staging "$staging" "$manifest"

  # 11) Hook post-install (em staging)
  run_hook "$portkey" "post-install" || log_warn "post-install hook não-zero"

  log_info "Build concluído com sucesso para $portkey ($portname v$portver). Staging: $staging"
  log_event "build" "$portkey" "$portver" "success" || true

  # Retorna caminho do staging
  echo "$staging"
  return 0
}

### Wrapper cmd_build
cmd_build(){
  local port="$1"
  if [ -z "$port" ]; then
    log_error "Uso: cmd_build <categoria/nome> ou caminho para portdir"
    return 2
  fi
  local port_dir
  if [ -d "$port" ] && [ -f "$port/Makefile" ]; then
    port_dir="$port"
  else
    port_dir="$PORTSDIR/$port"
  fi
  if [ ! -d "$port_dir" ]; then
    log_error "Port não encontrado: $port_dir"
    return 1
  fi
  build_port "$port_dir"
}

export -f cmd_build build_port

### Execução direta
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ $# -lt 1 ]; then
    echo "Uso: $0 <categoria/nome>  ou $0 /caminho/para/portdir"
    exit 1
  fi
  if [ -d "$1" ] && [ -f "$1/Makefile" ]; then
    build_port "$1"
  else
    cmd_build "$1"
  fi
fi
