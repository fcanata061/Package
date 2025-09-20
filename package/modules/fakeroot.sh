#!/usr/bin/env bash
# modules/fakeroot.sh
#
# Fornece funções para instalação sob ambiente "fakeroot",
# preservando metadados (uid, gid, permissões).
#
# Exporta:
#   run_under_fakeroot <cmd...>
#   fakeroot_install_from_staging <staging_dir> <port>
#   fakeroot_create_tarball <staging_dir> [out.tar]
#
# Lê variáveis de /etc/package.conf:
#   FAKEROOT_TOOL (fakeroot|fakechroot|rsync|tar)
#   PREFIX (/usr/local por padrão)
#   TRASH_DIR (/var/lib/package/trash por padrão)
#   UMASK (0022 por padrão)
#   RSYNC_CMD, TAR_CMD

set -euo pipefail

[ -f /etc/package.conf ] && source /etc/package.conf

FAKEROOT_TOOL=${FAKEROOT_TOOL:-fakeroot}
PREFIX=${PREFIX:-/usr/local}
TRASH_DIR=${TRASH_DIR:-/var/lib/package/trash}
UMASK=${UMASK:-0022}
RSYNC_CMD=${RSYNC_CMD:-rsync}
TAR_CMD=${TAR_CMD:-tar}

# --- Logging helpers ---
: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_error:=:}"

if ! declare -F log_info >/dev/null; then
  log_info(){ echo "[fakeroot][INFO] $*"; }
fi
if ! declare -F log_warn >/dev/null; then
  log_warn(){ echo "[fakeroot][WARN] $*"; }
fi
if ! declare -F log_error >/dev/null; then
  log_error(){ echo "[fakeroot][ERROR] $*" >&2; }
fi

# --- Funções ---

# run_under_fakeroot <cmd...>
# Executa comando sob fakeroot/fakechroot se disponível.
run_under_fakeroot() {
  if [ $# -lt 1 ]; then
    log_error "Uso: run_under_fakeroot <comando>"
    return 2
  fi

  if command -v "$FAKEROOT_TOOL" >/dev/null 2>&1; then
    case "$FAKEROOT_TOOL" in
      fakeroot)
        log_info "Executando sob fakeroot: $*"
        fakeroot -- "$@"
        ;;
      fakechroot)
        log_info "Executando sob fakechroot: $*"
        fakechroot "$@"
        ;;
      *)
        log_warn "Ferramenta $FAKEROOT_TOOL não reconhecida, executando diretamente."
        "$@"
        ;;
    esac
  else
    log_warn "Ferramenta fakeroot não encontrada, executando diretamente (pode requerer sudo): $*"
    "$@"
  fi
}

# fakeroot_install_from_staging <staging_dir> <port>
# Copia arquivos de staging para / preservando metadados.
fakeroot_install_from_staging() {
  local staging="$1" port="$2"

  [ -d "$staging" ] || {
    log_error "Diretório staging não existe: $staging"
    return 1
  }

  log_info "Instalando port $port de staging ($staging) para /"

  local tmp_archive
  tmp_archive="$(mktemp --tmpdir package-staging-XXXXXX.tar)" \
    || tmp_archive="/tmp/package-staging-$$.tar"

  (cd "$staging" && $TAR_CMD --numeric-owner -cf "$tmp_archive" .) \
    || { log_error "Falha ao criar tar do staging"; rm -f "$tmp_archive"; return 1; }

  if [ "$(id -u)" -eq 0 ]; then
    (cd / && $TAR_CMD --numeric-owner -xf "$tmp_archive") \
      || { log_error "Falha na extração como root"; rm -f "$tmp_archive"; return 1; }
  else
    if command -v sudo >/dev/null 2>&1; then
      sudo env UMASK="$UMASK" sh -c "cd / && $TAR_CMD --numeric-owner -xf '$tmp_archive'" \
        || { log_error "Falha na extração via sudo"; rm -f "$tmp_archive"; return 1; }
    else
      log_error "Necessário root ou sudo para instalar em /"
      rm -f "$tmp_archive"
      return 1
    fi
  fi

  rm -f "$tmp_archive"
  log_info "Instalação de $port concluída com sucesso"
}

# fakeroot_create_tarball <staging_dir> [out.tar]
# Cria tarball preservando donos/permissões.
fakeroot_create_tarball() {
  local staging="$1" out="${2:-}"
  [ -d "$staging" ] || {
    log_error "Staging não existe: $staging"
    return 1
  }
  [ -z "$out" ] && out="${staging%/}.tar"

  (cd "$staging" && $TAR_CMD --numeric-owner -cf "$out" .) \
    || { log_error "Falha ao criar tarball $out"; return 1; }

  log_info "Tarball criado: $out"
  printf '%s\n' "$out"
}

# --- Export ---
export -f run_under_fakeroot fakeroot_install_from_staging fakeroot_create_tarball

# Execução direta → help
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  cat <<EOF
Uso: source este módulo ou chame funções exportadas.

Funções disponíveis:
  run_under_fakeroot <cmd...>
  fakeroot_install_from_staging <staging_dir> <port>
  fakeroot_create_tarball <staging_dir> [out.tar]
EOF
fi
