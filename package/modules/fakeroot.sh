#!/usr/bin/env bash
# modules/fakeroot.sh
# Funções para operar em "fakeroot" / preservar metadados ao instalar de staging.
# Exporta:
#   run_under_fakeroot <cmd...>            # executa comando sob fakeroot (se disponível) ou simula
#   fakeroot_install_from_staging <staging> <port>  # instala staged files para / preservando metadados (usa sudo/tar/rsync)
#
# Comportamento:
# - Se binário `fakeroot` disponível, run_under_fakeroot executa via fakeroot -- <cmd>
# - fakeroot_install_from_staging usa tar to copy preserving uid/gid/mode; se precisa de root, usa sudo.
# - Ler /etc/package.conf para variáveis (TRASH_DIR, PREFIX, UMASK, FAKEROOT_TOOL)

set -euo pipefail

[ -f /etc/package.conf ] && source /etc/package.conf

FAKEROOT_TOOL=${FAKEROOT_TOOL:-fakeroot}   # preferido: fakeroot | fakechroot | tar
PREFIX=${PREFIX:-/usr/local}
TRASH_DIR=${TRASH_DIR:-/var/lib/package/trash}
UMASK=${UMASK:-0022}
RSYNC_CMD=${RSYNC_CMD:-rsync}
TAR_CMD=${TAR_CMD:-tar}

# logging fallbacks
: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_error:=:}"
if ! declare -F log_info >/dev/null; then log_info(){ echo "[fakeroot][INFO] $*"; }; fi
if ! declare -F log_warn >/dev/null; then log_warn(){ echo "[fakeroot][WARN] $*"; }; fi
if ! declare -F log_error >/dev/null; then log_error(){ echo "[fakeroot][ERROR] $*" >&2; }; fi

# execute command under fakeroot if available, else try fallback (just run or sudo-run)
run_under_fakeroot(){
  if [ $# -lt 1 ]; then log_error "run_under_fakeroot: comando ausente"; return 2; fi
  if command -v "$FAKEROOT_TOOL" >/dev/null 2>&1; then
    # prefer explicit fakeroot invocation
    if [ "$FAKEROOT_TOOL" = "fakeroot" ]; then
      log_info "Executando comando sob fakeroot: $*"
      fakeroot -- "$@"
      return $?
    elif [ "$FAKEROOT_TOOL" = "fakechroot" ]; then
      log_info "Executando comando sob fakechroot: $*"
      fakechroot "$@"
      return $?
    fi
  fi
  # fallback: run normally (may require sudo for operations that need root)
  log_warn "Ferramenta fakeroot ($FAKEROOT_TOOL) não disponível; executando comando diretamente (pode requerer sudo): $*"
  "$@"
}

# Install staged files into real root preserving metadata.
# Uses tar to pack from staging and extract to / with numeric owner preserved.
# If not root, uses sudo for extraction.
# Usage: fakeroot_install_from_staging <staging_dir> <port>
fakeroot_install_from_staging(){
  local staging="$1" port="$2"
  [ -d "$staging" ] || { log_error "fakeroot_install_from_staging: staging não existe: $staging"; return 1; }
  log_info "Instalando de staging ($staging) para sistema (preservando metadados) para port $port"

  # create archive (use portable tar)
  local tmp_archive
  tmp_archive="$(mktemp --tmpdir package-tar-XXXXXX.tar)" || tmp_archive="/tmp/package-tar-$$.tar"
  # create tar with numeric ids preserved
  (cd "$staging" && $TAR_CMD --numeric-owner -cf "$tmp_archive" .) || { log_error "Falha ao criar tar de staging"; rm -f "$tmp_archive"; return 1; }

  # extract archive to / (needs root)
  if [ "$(id -u)" -eq 0 ]; then
    log_info "Extraindo $tmp_archive para / como root"
    (cd / && $TAR_CMD --numeric-owner -xf "$tmp_archive") || { log_error "Falha na extração como root"; rm -f "$tmp_archive"; return 1; }
  else
    if command -v sudo >/dev/null 2>&1; then
      log_info "Extraindo $tmp_archive para / via sudo tar"
      sudo env UMASK="$UMASK" sh -c "cd / && $TAR_CMD --numeric-owner -xf '$tmp_archive'" || { log_error "sudo tar falhou"; rm -f "$tmp_archive"; return 1; }
    else
      log_error "Necessário root/sudo para extrair arquivos para /; extração abortada"
      rm -f "$tmp_archive"
      return 1
    fi
  fi

  rm -f "$tmp_archive"
  log_info "Instalação a partir de staging concluída para $port"
  return 0
}

# Helper: create a tarball from staging (for registry or archival)
fakeroot_create_tarball(){
  local staging="$1" out="${2:-}"
  [ -d "$staging" ] || { log_error "fakeroot_create_tarball: staging não existe"; return 1; }
  if [ -z "$out" ]; then out="${staging%/}.tar"; fi
  (cd "$staging" && $TAR_CMD --numeric-owner -cf "$out" .) || { log_error "falha ao criar tarball $out"; return 1; }
  log_info "Tarball criado: $out"
  printf '%s' "$out"
  return 0
}

# Provide export so other modules can use
export -f run_under_fakeroot fakeroot_install_from_staging fakeroot_create_tarball

# If invoked as script, show help
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  cat <<EOF
fakeroot.sh - helpers
Functions exported:
  run_under_fakeroot <cmd...>
  fakeroot_install_from_staging <staging_dir> <port>
  fakeroot_create_tarball <staging_dir> [out.tar]
EOF
fi
