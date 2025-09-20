#!/usr/bin/env bash
# modules/fetch.sh
#
# Responsável por baixar os sources dos ports.
# Suporta: http(s), ftp, git, rsync, arquivos locais.
#
# Variáveis de ambiente/Makefile esperadas:
#   SRC_URI    -> URLs separadas por espaço
#   DISTFILES  -> nomes dos arquivos resultantes (um para cada SRC_URI)
#   DISTDIR    -> diretório destino dos distfiles (padrão /var/cache/package/distfiles)
#   WORKDIR    -> diretório de trabalho do build (padrão /usr/ports/work/<port>)
#
# Exporta:
#   fetch_sources <port_dir>

set -euo pipefail

[ -f /etc/package.conf ] && source /etc/package.conf

DISTDIR=${DISTDIR:-/var/cache/package/distfiles}
WORKDIR=${WORKDIR:-/usr/ports/work}

# --- Logging helpers ---
: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_error:=:}"

if ! declare -F log_info >/dev/null; then
  log_info(){ echo "[fetch][INFO] $*"; }
fi
if ! declare -F log_warn >/dev/null; then
  log_warn(){ echo "[fetch][WARN] $*"; }
fi
if ! declare -F log_error >/dev/null; then
  log_error(){ echo "[fetch][ERROR] $*" >&2; }
fi

mkdir -p "$DISTDIR" "$WORKDIR"

# --- Funções internas ---

_fetch_http() {
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -L -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$out" "$url"
  else
    log_error "Nem curl nem wget disponíveis"
    return 1
  fi
}

_fetch_git() {
  local url="$1" out="$2"
  if [ -d "$out/.git" ]; then
    log_info "Atualizando repositório git $url"
    git -C "$out" fetch --all --tags
  else
    log_info "Clonando repositório git $url"
    git clone --recursive "$url" "$out"
  fi
}

_fetch_rsync() {
  local url="$1" out="$2"
  log_info "Baixando via rsync $url"
  rsync -av "$url" "$out"
}

# --- Função principal ---

fetch_sources() {
  local port_dir="$1"
  [ -f "$port_dir/Makefile" ] || {
    log_error "Makefile não encontrado em $port_dir"
    return 1
  }

  # Carregar variáveis do Makefile
  local src_uri distfiles
  src_uri=$(make -C "$port_dir" -s -f Makefile -V SRC_URI || true)
  distfiles=$(make -C "$port_dir" -s -f Makefile -V DISTFILES || true)

  if [ -z "$src_uri" ]; then
    log_warn "Nenhuma SRC_URI definida para $port_dir"
    return 0
  fi

  local -a uris files
  IFS=' ' read -r -a uris <<< "$src_uri"
  IFS=' ' read -r -a files <<< "$distfiles"

  if [ "${#files[@]}" -gt 0 ] && [ "${#files[@]}" -ne "${#uris[@]}" ]; then
    log_warn "DISTFILES não corresponde a SRC_URI, ignorando nomes customizados"
    files=()
  fi

  for i in "${!uris[@]}"; do
    local url="${uris[$i]}"
    local fname="${files[$i]:-$(basename "$url")}"
    local out="$DISTDIR/$fname"

    case "$url" in
      http://*|https://*|ftp://*)
        if [ -f "$out" ]; then
          log_info "Usando cache existente: $out"
        else
          log_info "Baixando $url → $out"
          _fetch_http "$url" "$out"
        fi
        ;;
      git://*|*.git|ssh://*|https://*.git)
        local repo_dir="$DISTDIR/${fname%.git}"
        _fetch_git "$url" "$repo_dir"
        ;;
      rsync://*)
        _fetch_rsync "$url" "$DISTDIR/$fname"
        ;;
      file://*)
        local src="${url#file://}"
        cp -av "$src" "$out"
        ;;
      *)
        if [ -f "$url" ]; then
          cp -av "$url" "$out"
        else
          log_error "Protocolo não suportado ou arquivo inexistente: $url"
          return 1
        fi
        ;;
    esac
  done
}

# --- Export ---
export -f fetch_sources

# Execução direta
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ $# -lt 1 ]; then
    echo "Uso: $0 <port_dir>"
    exit 1
  fi
  fetch_sources "$1"
fi

# --- Integração com o bin/package ---
cmd_fetch() {
  local port="$1"
  if [ -z "$port" ]; then
    log_error "uso: package fetch <portdir>"
    return 2
  fi
  fetch_sources "$PORTSDIR/$port"
}
