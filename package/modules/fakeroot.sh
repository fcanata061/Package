#!/usr/bin/env bash
# modules/fakeroot.sh
# --- Simulação de root para instalação de ports ---
#
# Permite instalar arquivos no sistema preservando metadados de dono/permissões
# sem precisar de root real. Usa 'fakeroot' se disponível, ou fallback com root.
#
# Funções expostas:
#   fakeroot_install <stagedir> <categoria/port>
#   fakeroot_showmeta <categoria/port>
#   fakeroot_clean <categoria/port>
#
# Banco de metadados:
#   /var/lib/package/metadata/<port>.meta
#
# Integração: substitui a função copy_from_staged_to_root do sandbox-build.sh

FAKEROOT_BIN=${FAKEROOT_BIN:-$(command -v fakeroot 2>/dev/null || true)}
META_DIR=${META_DIR:-/var/lib/package/metadata}
PREFIX=${PREFIX:-/usr/local}

mkdir -p "$META_DIR"

: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_debug:=:}"
: "${err:=:}"

if ! declare -F log_info >/dev/null; then log_info(){ echo "[fakeroot][INFO] $*"; }; fi
if ! declare -F log_warn >/dev/null; then log_warn(){ echo "[fakeroot][WARN] $*"; }; fi
if ! declare -F log_debug >/dev/null; then log_debug(){ [ "${DEBUG:-0}" -eq 1 ] && echo "[fakeroot][DEBUG] $*"; }; fi
if ! declare -F err >/dev/null; then err(){ echo "[fakeroot][ERROR] $*" >&2; }; fi

# -----------------------------------------------------------------------------
# Função principal: instalar com fakeroot
# -----------------------------------------------------------------------------
fakeroot_install() {
  local stagedir="$1"
  local port="$2"

  [ -d "$stagedir" ] || { err "Stagedir inválido: $stagedir"; return 2; }
  [ -n "$port" ] || { err "Port não informado"; return 2; }

  local metafile="$META_DIR/$(echo "$port" | tr '/' '_').meta"
  rm -f "$metafile"

  if [ -n "$FAKEROOT_BIN" ] && [ -x "$FAKEROOT_BIN" ]; then
    log_info "Instalando $port com fakeroot (metadados capturados em $metafile)"

    # Usamos tar dentro do fakeroot para capturar metadata corretamente
    $FAKEROOT_BIN bash -c "
      cd '$stagedir' || exit 1
      # gravar metadata de permissões/dono em metafile
      find . -printf '%M %u %g %p\n' > '$metafile'
      tar -cf - . | (cd / && tar -xf -)
    " || return 1

  else
    log_warn "fakeroot não disponível — usando fallback (pode precisar de root)"
    if [ "$(id -u)" -ne 0 ]; then
      err "Sem fakeroot e não é root — abortando instalação"
      return 1
    fi
    (cd "$stagedir" && find . -printf '%M %u %g %p\n') > "$metafile"
    (cd "$stagedir" && tar --numeric-owner -cf - . | (cd / && tar -xf -)) || return 1
  fi

  log_info "Instalação de $port concluída. Metadados salvos em $metafile"
  return 0
}

# -----------------------------------------------------------------------------
# Mostrar metadados salvos
# -----------------------------------------------------------------------------
fakeroot_showmeta() {
  local port="$1"
  local metafile="$META_DIR/$(echo "$port" | tr '/' '_').meta"
  if [ -f "$metafile" ]; then
    cat "$metafile"
  else
    err "Nenhum metadado encontrado para $port"
    return 1
  fi
}

# -----------------------------------------------------------------------------
# Limpar metadados de um port
# -----------------------------------------------------------------------------
fakeroot_clean() {
  local port="$1"
  local metafile="$META_DIR/$(echo "$port" | tr '/' '_').meta"
  rm -f "$metafile"
  log_info "Metadados removidos para $port"
}
