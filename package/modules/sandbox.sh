#!/usr/bin/env bash
# modules/sandbox-build.sh
# --- Executa todo o processo de build dentro de sandbox ---
#
# Funções exposas:
#  - cmd_build_sandbox <categoria/port>
#  - prepare_sandbox <port> (reusa sandbox.sh se presente)
#  - run_in_sandbox <inst> "<cmd...>" (reusa sandbox.sh se presente)
#  - cleanup_sandbox <port>
#
# Fluxo high-level (cmd_build_sandbox):
#  1. resolve deps (se dependency.sh presente -> cmd_deps)
#  2. preparar sandbox (prepare_sandbox)
#  3. dentro do sandbox:
#     a) executar hooks pre_configure
#     b) executar fetch (make fetch / wget fallback)
#     c) executar configure/build (make build / make)
#     d) executar hooks post_configure
#     e) executar make install para STAGEDIR
#  4. extrair lista de arquivos instalados do STAGEDIR, salvar /var/lib/package/files/<port>.list
#  5. copiar do STAGEDIR para o sistema real (usando fakeroot se disponível)
#  6. atualizar INSTALLED_DB com versão/timestamp
#  7. executar hooks post_install
#  8. registrar logs e cleanup (opcional preservar sandbox se DEBUG)
#
# Requisitos opcionais:
#  - fakeroot instalado (para install sem root)
#  - git/wget para fetch
#
# Variáveis configuráveis (pode definir em /etc/package.conf):
#   SANDBOX_BASE, DEPS_CACHE, INSTALLED_DB, PREFIX, CACHE_DIR, MAKEFLAGS, FAKEROOT_DIR
#
# Este módulo tenta usar prepare_sandbox/run_in_sandbox/cleanup_sandbox/other functions
# definidas no módulo sandbox.sh. Se não existirem, fornece fallback interno simples.

# ---------- Config/paths (podem ser sobrescritas em /etc/package.conf) ----------
PORTSDIR=${PORTSDIR:-/usr/ports}
CACHE_DIR=${CACHE_DIR:-/var/cache/package}
DEPS_CACHE=${DEPS_CACHE:-/var/lib/package/deps}
INSTALLED_DB=${INSTALLED_DB:-/var/lib/package/installed}
FILES_DIR=${FILES_DIR:-/var/lib/package/files}
PREFIX=${PREFIX:-/usr/local}
MAKEFLAGS=${MAKEFLAGS:-"-j$(nproc)"}
FAKEROOT_BIN=${FAKEROOT_BIN:-$(command -v fakeroot 2>/dev/null || true)}
SANDBOX_KEEP_ON_FAIL=${SANDBOX_KEEP_ON_FAIL:-false}

mkdir -p "$CACHE_DIR" "$DEPS_CACHE" "$(dirname "$INSTALLED_DB")" "$FILES_DIR"

# ---------- logging fallbacks ----------
: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_debug:=:}"
: "${err:=:}"
if ! declare -F log_info >/dev/null; then log_info(){ echo "[package][INFO] $*"; }; fi
if ! declare -F log_warn >/dev/null; then log_warn(){ echo "[package][WARN] $*"; }; fi
if ! declare -F log_debug >/dev/null; then log_debug(){ [ "${DEBUG:-0}" -eq 1 ] && echo "[package][DEBUG] $*"; }; fi
if ! declare -F err >/dev/null; then err(){ echo "[package][ERROR] $*" >&2; }; fi

# ---------- Try to reuse sandbox.sh functions if available ----------
# If the environment already sourced sandbox.sh, use its functions.
if ! declare -F prepare_sandbox >/dev/null; then
  # minimal internal prepare_sandbox fallback (creates a simple dir)
  prepare_sandbox() {
    local port="$1"
    local base=${SANDBOX_BASE:-/var/sandbox/package}
    mkdir -p "$base"
    local inst="$base/$(echo "$port" | tr '/' '_')/instance-$(date +%s)"
    mkdir -p "$inst"
    # mount minimal binds if root
    if [ "$(id -u)" -eq 0 ]; then
      for p in /dev /proc /sys; do
        mkdir -p "$inst/$p"
        mount --bind "$p" "$inst/$p" 2>/dev/null || true
      done
      # bind ports tree
      mkdir -p "$inst/$PORTSDIR"
      mount --bind "$PORTSDIR" "$inst/$PORTSDIR" 2>/dev/null || true
      mkdir -p "$inst/$CACHE_DIR"
      mount --bind "$CACHE_DIR" "$inst/$CACHE_DIR" 2>/dev/null || true
    fi
    echo "$inst"
  }
fi

if ! declare -F run_in_sandbox >/dev/null; then
  # basic run_in_sandbox fallback using chroot (requires root)
  run_in_sandbox() {
    local inst="$1"; shift
    local cmd="$*"
    if [ "$(id -u)" -ne 0 ]; then
      if command -v proot >/dev/null 2>&1; then
        proot -R "$inst" /bin/bash -lc "$cmd"
        return $?
      fi
      err "No available sandbox runtime (need systemd-nspawn or root for chroot or proot)"
      return 3
    fi
    chroot "$inst" /bin/bash -lc "$cmd"
    return $?
  }
fi

if ! declare -F cleanup_sandbox >/dev/null; then
  cleanup_sandbox() {
    local port="$1"
    local base=${SANDBOX_BASE:-/var/sandbox/package}
    local dir="$base/$(echo "$port" | tr '/' '_')"
    if [ -d "$dir" ]; then
      # best-effort unmounts if root
      if [ "$(id -u)" -eq 0 ]; then
        awk "\$2 ~ /^$dir/ {print \$2}" /proc/mounts 2>/dev/null | sort -r | while read -r m; do
          umount -l "$m" 2>/dev/null || true
        done
      fi
      rm -rf "$dir"
    fi
  }
fi

# ---------- helpers ----------
record_installed() {
  local port="$1"
  local ver="$2"
  local now
  now=$(date --iso-8601=seconds 2>/dev/null || date)
  # if already present, replace; else append
  grep -v "^$port " "$INSTALLED_DB" 2>/dev/null > "$INSTALLED_DB.tmp" || true
  echo "$port $ver $now" >> "$INSTALLED_DB.tmp"
  mv "$INSTALLED_DB.tmp" "$INSTALLED_DB"
}

write_files_list() {
  local port="$1" stagedir="$2"  # stagedir is path within host FS (not inside sandbox) or absolute
  local listfile="$FILES_DIR/$(echo "$port" | tr '/' '_').list"
  # Find all installed files under stagedir and store their absolute path as installed location
  rm -f "$listfile"
  if [ -d "$stagedir" ]; then
    (cd "$stagedir" && find . -type f -printf '%P\n' | sed "s|^|$PREFIX/|") > "$listfile" 2>/dev/null || true
  fi
  log_info "Lista de arquivos gravada em $listfile"
}

copy_from_staged_to_root() {
  local stagedir="$1"
  # copy preserving metadata; if fakeroot available wrap in fakeroot
  if [ -z "$stagedir" ] || [ ! -d "$stagedir" ]; then
    err "Stagedir inválido: $stagedir"
    return 2
  fi

  if [ -n "$FAKEROOT_BIN" ] && [ -x "$FAKEROOT_BIN" ]; then
    log_info "Copiando arquivos do stagedir para sistema com fakeroot"
    # Using fakeroot to simulate owner/perm changes during install
    $FAKEROOT_BIN bash -c "cd '$stagedir' && tar -cf - . | (cd / && tar -xf -)" || return $?
  else
    log_info "Copiando arquivos do stagedir para sistema (necessita privilégios se for /usr etc)"
    if [ "$(id -u)" -ne 0 ]; then
      log_warn "Não sou root e fakeroot não disponível — instalação pode falhar"
    fi
    (cd "$stagedir" && tar -cf - . | (cd / && tar -xf -)) || return $?
  fi
  return 0
}

# ---------- internal: build script that will run inside sandbox ----------
# We will create a small script inside the sandbox instance to run the sequence.
# The script will:
#  - cd /usr/ports/<port>
#  - run optionally: make fetch
#  - run configure/build: make build || make all || make
#  - run make install DESTDIR=/staging PREFIX=/usr/local
#  - leave /staging populated
create_inner_build_script() {
  local inst="$1" port="$2" stagedir_rel="$3"
  local inner_script="$inst/.build_script.sh"
  cat > "$inner_script" <<'INNER'
#!/usr/bin/env bash
set -euo pipefail
PORT="$1"
PREFIX="${PREFIX:-/usr/local}"
STAGEDIR="$2"   # inside chroot instance absolute path (eg /staging)
LOG="/tmp/package_build.log"
echo "[inner] start build $PORT" > "$LOG"

cd "$PORT" || { echo "Port dir not found: $PORT" >> "$LOG"; exit 2; }

# try fetch
if make -n fetch >/dev/null 2>&1; then
  echo "[inner] running make fetch" >> "$LOG"
  make fetch || echo "fetch failed (non-fatal)" >> "$LOG"
fi

# run configure if present (some ports have configure target)
if make -n configure >/dev/null 2>&1; then
  echo "[inner] running make configure" >> "$LOG"
  make configure || echo "configure failed (non-fatal)" >> "$LOG"
fi

# build: prefer 'build' target, fallback to 'all' or plain make
if make -n build >/dev/null 2>&1; then
  echo "[inner] running make build" >> "$LOG"
  make build ${MAKEFLAGS:-} || { echo "build failed" >> "$LOG"; exit 3; }
elif make -n all >/dev/null 2>&1; then
  echo "[inner] running make all" >> "$LOG"
  make all ${MAKEFLAGS:-} || { echo "all build failed" >> "$LOG"; exit 3; }
else
  echo "[inner] running plain make" >> "$LOG"
  make ${MAKEFLAGS:-} || { echo "make failed" >> "$LOG"; exit 3; }
fi

# ensure stagedir exists
mkdir -p "$STAGEDIR"

# install into stagedir
if make -n install >/dev/null 2>&1; then
  echo "[inner] running make install DESTDIR=$STAGEDIR PREFIX=$PREFIX" >> "$LOG"
  make install DESTDIR="$STAGEDIR" PREFIX="$PREFIX" ${MAKEFLAGS:-} || { echo "install failed" >> "$LOG"; exit 4; }
else
  # fallback: try 'install' target absent -> try 'make install' anyway
  echo "[inner] running fallback make install DESTDIR=$STAGEDIR PREFIX=$PREFIX" >> "$LOG"
  make install DESTDIR="$STAGEDIR" PREFIX="$PREFIX" ${MAKEFLAGS:-} || { echo "install failed" >> "$LOG"; exit 4; }
fi

echo "[inner] build finished" >> "$LOG"
exit 0
INNER

  chmod +x "$inner_script" || true
  # return path to inner script and expected args
  printf '%s\n' "$inner_script"
}

# ---------- main function: cmd_build_sandbox ----------
# Usage: cmd_build_sandbox <categoria/port>
cmd_build_sandbox() {
  local port="$1"
  [ -n "$port" ] || { err "Uso: package build <categoria/port>"; return 2; }

  log_info "Iniciando build sandboxed para $port"
  # 1) run dependency resolution if available
  if declare -F cmd_deps >/dev/null; then
    log_info "Resolvendo dependências (BUILD_DEPENDS, RUN_DEPENDS, TEST_DEPENDS)..."
    cmd_deps "$port" || { err "Falha ao resolver dependências"; return 1; }
  else
    log_debug "cmd_deps não disponível — pulando resolução automática"
  fi

  # 2) Prepare sandbox
  local inst
  inst=$(prepare_sandbox "$port") || { err "Falha ao preparar sandbox"; return 1; }
  log_info "Sandbox criada em: $inst"

  # stagedir is inside the instance root (absolute path there)
  local stagedir="/staging"
  # ensure stagedir exists on host under instance to collect later
  mkdir -p "$inst$stagedir"

  # 3) create inner build script (host side file inside instance)
  local inner_script
  inner_script=$(create_inner_build_script "$inst" "/$PORTSDIR/$port" "$stagedir") || { err "Falha ao criar script interno"; [ "$SANDBOX_KEEP_ON_FAIL" = true ] || cleanup_sandbox "$port"; return 1; }

  # 4) run pre_configure hook if available (call from host side if function exists)
  if declare -F run_pre_configure >/dev/null; then
    run_pre_configure "$port" || { err "pre_configure hook falhou"; [ "$SANDBOX_KEEP_ON_FAIL" = true ] || cleanup_sandbox "$port"; return 1; }
  fi

  # 5) execute the inner script inside sandbox
  # Pass arguments: port directory inside chroot (e.g. /usr/ports/net/httpd) and stagedir (/staging)
  local cmd_inner
  cmd_inner="/.build_script.sh '/$PORTSDIR/$port' '$stagedir'"

  # Copy inner script into instance root (already created at $inst/.build_script.sh)
  # ensure it's executable inside instance file system
  chmod +x "$inst/.build_script.sh" 2>/dev/null || true

  log_info "Executando build dentro da sandbox..."
  run_in_sandbox "$inst" "/.build_script.sh '/$PORTSDIR/$port' '$stagedir'" || {
    err "Falha no build dentro da sandbox"
    # leave sandbox for debugging if configured
    if [ "$SANDBOX_KEEP_ON_FAIL" = true ]; then
      log_warn "Sandbox preservada em $inst para análise"
      return 1
    else
      cleanup_sandbox "$port"
      return 1
    fi
  }

  log_info "Build concluído dentro da sandbox. Coletando artefatos..."

  # 6) Collect files list from stagedir on host ($inst$stagedir)
  local host_stagedir="$inst$stagedir"
  if [ ! -d "$host_stagedir" ]; then
    err "Stagedir não encontrado: $host_stagedir"
    cleanup_sandbox "$port"
    return 1
  fi

  # write files list (absolute paths where they will be installed on the real system)
  write_files_list "$port" "$host_stagedir"

  # 7) copy from stagedir to root (install)
  log_info "Instalando arquivos no sistema a partir do stagedir..."
  if ! copy_from_staged_to_root "$host_stagedir"; then
    err "Falha ao copiar arquivos do stagedir para o sistema"
    [ "$SANDBOX_KEEP_ON_FAIL" = true ] || cleanup_sandbox "$port"
    return 1
  fi

  # 8) Optionally run post_install hooks
  if declare -F run_post_install >/dev/null; then
    run_post_install "$port" || { err "post_install hook falhou"; [ "$SANDBOX_KEEP_ON_FAIL" = true ] || cleanup_sandbox "$port"; return 1; }
  fi

  # 9) Update INSTALLED_DB with version detection (try to parse Makefile VERSION or use timestamp)
  local version="unknown"
  local makefile="$PORTSDIR/$port/Makefile"
  if [ -f "$makefile" ]; then
    version=$(grep -E '^(VERSION|PORTVERSION|PORTNAME)[[:space:]]*=' "$makefile" | head -n1 | awk -F= '{print $2}' | tr -d ' "')
    version=${version:-"unknown"}
  fi
  record_installed "$port" "$version"
  register_action "install" "$port" "success" 2>/dev/null || true

  log_info "Instalação concluída para $port (versão: $version)"

  # 10) cleanup sandbox unless configured to keep
  if [ "$SANDBOX_KEEP_ON_FAIL" = true ] || [ "${SANDBOX_KEEP:-false}" = true ]; then
    log_info "Preservando sandbox (SANDBOX_KEEP enabled): $inst"
  else
    cleanup_sandbox "$port"
  fi

  return 0
}

# Export function to be used by CLI when sourced
# The CLI's `package` script should call `cmd_build_sandbox` instead of the older cmd_build
# or you can alias cmd_build -> cmd_build_sandbox in package main.
