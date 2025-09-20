#!/usr/bin/env bash
# modules/install.sh
# cmd_install <categoria/port>
# - Se DESTDIR já definido e contém arquivos, usa ele como staging.
# - Caso contrário, cria staging e executa make install DESTDIR=staging.
# - Sincroniza staging -> / (usa sudo se necessário)
# - Gera lista de arquivos instalados em FILES_DIR/<categoria_port>.list
# - Chama hooks pre-install/post-install e register_install

set -euo pipefail

[ -f /etc/package.conf ] && source /etc/package.conf

PORTSDIR=${PORTSDIR:-/usr/ports}
FILES_DIR=${FILES_DIR:-/var/lib/package/files}
PREFIX=${PREFIX:-/usr/local}
MAKE_INSTALL_CMD=${INSTALL_CMD:-"make DESTDIR=\$DESTDIR install"}

ALLOW_UNPRIVILEGED_BUILDS=${ALLOW_UNPRIVILEGED_BUILDS:-yes}
UMASK=${UMASK:-0022}
mkdir -p "$FILES_DIR"

# logging fallbacks
: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_error:=:}"
if ! declare -F log_info >/dev/null; then log_info(){ echo "[install][INFO] $*"; }; fi
if ! declare -F log_warn >/dev/null; then log_warn(){ echo "[install][WARN] $*"; }; fi
if ! declare -F log_error >/dev/null; then log_error(){ echo "[install][ERROR] $*" >&2; }; fi

: "${run_hook:=:}"
if ! declare -F run_hook >/dev/null; then run_hook(){ log_info "Hook runner não implementado: $*"; return 0; }; fi
: "${register_install:=:}"
if ! declare -F register_install >/dev/null; then register_install(){ log_warn "register_install não implementado; pretendendo registrar $1 $2"; }; fi

_run_as_root(){
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    if command -v sudo >/dev/null 2>&1; then
      sudo "$@"
    else
      log_error "Operação exige root (ou sudo): $*"
      return 1
    fi
  fi
}

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

# write files list from staging: strips staging prefix and writes final paths
_write_files_list_from_staging(){
  local port="$1" staging="$2"
  local listfile="$FILES_DIR/$(echo "$port" | tr '/' '_').list"
  mkdir -p "$(dirname "$listfile")"
  : > "$listfile"
  # find files (not directories), record final path (strip staging)
  (cd "$staging" && find . -type f -print0) | while IFS= read -r -d '' f; do
    # normalize
    local rel="${f#./}"
    # final path
    local final="/${rel}"
    printf '%s\n' "$final" >> "$listfile"
  done
  log_info "Lista de arquivos escrita em $listfile"
}

# copy staging -> real filesystem (rsync)
_sync_staging_to_root(){
  local staging="$1"
  # require root to copy
  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
      log_info "Sincronizando staging -> / usando sudo rsync"
      sudo rsync -a --no-times --omit-dir-times "$staging"/ /
    else
      log_error "Não sou root e sudo não disponível — não é possível sincronizar para /"
      return 1
    fi
  else
    log_info "Sincronizando staging -> / (root)"
    rsync -a --no-times --omit-dir-times "$staging"/ /
  fi
}

cmd_install() {
  local port="$1"
  [ -n "$port" ] || { log_error "Uso: package install <categoria/port>"; return 2; }

  local mf="$PORTSDIR/$port/Makefile"
  if [ ! -f "$mf" ]; then log_error "Makefile não encontrado para $port"; return 1; fi

  # run pre-install hook
  run_hook "$port" "pre-install" || log_warn "pre-install hook falhou (continuando)"

  # Determine staging directory
  local staging_provided=0
  local staging="${DESTDIR:-}"
  if [ -n "$staging" ] && [ -d "$staging" ] && [ "$(find "$staging" -mindepth 1 | wc -l)" -gt 0 ]; then
    staging_provided=1
    log_info "Usando staging existente: $staging"
  else
    staging_provided=0
    staging=$(mktemp -d -p /tmp package-staging-XXXXXX) || staging="/tmp/package-staging-$$"
    mkdir -p "$staging"
    log_info "Criado staging temporário: $staging"
    # run 'make install DESTDIR=staging' (respect build system)
    # detect build dir: prefer workdir/build or PORTSDIR/port/build
    local builddir
    if [ -d "$PORTSDIR/$port/build" ]; then builddir="$PORTSDIR/$port/build"; else builddir="$PORTSDIR/$port"; fi

    # attempt ninja/cmake/meson detection
    if [ -f "$builddir/build.ninja" ] || [ -f "$builddir/ninja.build" ]; then
      (cd "$builddir" && ninja install DESTDIR="$staging") || { log_error "ninja install falhou em $builddir"; rm -rf "$staging"; return 1; }
    else
      # generic make install DESTDIR
      (cd "$builddir" && eval $MAKE_INSTALL_CMD) || { log_error "make install falhou em $builddir"; rm -rf "$staging"; return 1; }
    fi
    log_info "Instalação em staging ($staging) concluída"
  fi

  # generate files list
  _write_files_list_from_staging "$port" "$staging"

  # sync to real filesystem
  if [ "$staging_provided" -eq 1 ]; then
    log_info "DESTDIR fornecido; sincronizando staging -> /"
  else
    log_info "Movendo staged files para o sistema"
  fi

  _sync_staging_to_root "$staging" || { log_error "Falha ao sincronizar staging para /"; [ "$staging_provided" -eq 0 ] && rm -rf "$staging"; return 1; }

  # register installed package with version
  local version
  version=$(_makefile_var "$mf" "VERSION")
  [ -z "$version" ] && version=$(_makefile_var "$mf" "PORTVERSION")
  [ -z "$version" ] && version="unknown"
  register_install "$port" "$version"

  # run post-install hook
  run_hook "$port" "post-install" || log_warn "post-install hook falhou (continuando)"

  # cleanup staging if we created it
  if [ "$staging_provided" -eq 0 ]; then
    rm -rf "$staging"
    log_info "Staging temporário removido"
  fi

  log_info "Instalação de $port concluída e registrada (versão: $version)"
  return 0
}

export -f cmd_install
