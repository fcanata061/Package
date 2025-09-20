#!/usr/bin/env bash
# modules/patch.sh
# --- Aplicação de patches em ports ---
#
# Estrutura esperada:
#   /usr/ports/<categoria>/<port>/patches/*.patch
#   /usr/ports/<categoria>/<port>/patches/*.diff
#
# Funções:
#   patch_apply <port_path> <srcdir>
#   patch_list <port_path>
#   patch_clean <port_path>
#
# Integração: deve ser chamado dentro do build.sh,
# após extrair o tarball mas antes de rodar ./configure.

PORTSDIR=${PORTSDIR:-/usr/ports}
PATCH_LOG_DIR=${PATCH_LOG_DIR:-/var/log/package/patches}
mkdir -p "$PATCH_LOG_DIR"

: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_error:=:}"

if ! declare -F log_info >/dev/null; then log_info(){ echo "[patch][INFO] $*"; }; fi
if ! declare -F log_warn >/dev/null; then log_warn(){ echo "[patch][WARN] $*"; }; fi
if ! declare -F log_error >/dev/null; then log_error(){ echo "[patch][ERROR] $*" >&2; }; fi

# -----------------------------------------------------------------------------
# Listar patches disponíveis para um port
# -----------------------------------------------------------------------------
patch_list() {
  local port_path="$1"
  local patchdir="$PORTSDIR/$port_path/patches"

  if [ -d "$patchdir" ]; then
    find "$patchdir" -type f \( -name "*.patch" -o -name "*.diff" \) | sort
  fi
}

# -----------------------------------------------------------------------------
# Aplicar patches
# -----------------------------------------------------------------------------
patch_apply() {
  local port_path="$1"
  local srcdir="$2"

  local patchdir="$PORTSDIR/$port_path/patches"
  [ -d "$srcdir" ] || { log_error "Diretório fonte inválido: $srcdir"; return 2; }

  local patches
  patches=$(patch_list "$port_path")

  if [ -z "$patches" ]; then
    log_info "Nenhum patch encontrado para $port_path"
    return 0
  fi

  log_info "Aplicando patches de $port_path"
  local logfile="$PATCH_LOG_DIR/$(echo "$port_path" | tr '/' '_').log"
  rm -f "$logfile"

  for patchfile in $patches; do
    log_info "Aplicando $(basename "$patchfile")"
    if patch -d "$srcdir" -p1 < "$patchfile" >>"$logfile" 2>&1; then
      log_info "Patch $(basename "$patchfile") aplicado com sucesso"
    else
      log_error "Falha ao aplicar $(basename "$patchfile"), verifique $logfile"
      return 1
    fi
  done

  log_info "Todos os patches aplicados com sucesso em $port_path"
  return 0
}

# -----------------------------------------------------------------------------
# Limpar logs de patches de um port
# -----------------------------------------------------------------------------
patch_clean() {
  local port_path="$1"
  local logfile="$PATCH_LOG_DIR/$(echo "$port_path" | tr '/' '_').log"
  rm -f "$logfile"
  log_info "Logs de patches limpos para $port_path"
}
