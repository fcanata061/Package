#!/usr/bin/env bash
# modules/update.sh
#
# Busca novas versões de todos os programas no repositório de ports.
# Suporta fontes: git, http(s), ftp, file://.
#
# Salva informações em: /var/lib/package/updates/<port>.json
# Notifica via notify-send quando novas versões são encontradas.
#
# Variáveis de /etc/package.conf:
#   PORTSDIR=/usr/ports
#   UPDATESDIR=/var/lib/package/updates

set -euo pipefail

[ -f /etc/package.conf ] && source /etc/package.conf

PORTSDIR=${PORTSDIR:-/usr/ports}
UPDATESDIR=${UPDATESDIR:-/var/lib/package/updates}
mkdir -p "$UPDATESDIR"

# --- Logging helpers ---
: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_error:=:}"

if ! declare -F log_info >/dev/null; then
  log_info(){ echo "[update][INFO] $*"; }
fi
if ! declare -F log_warn >/dev/null; then
  log_warn(){ echo "[update][WARN] $*"; }
fi
if ! declare -F log_error >/dev/null; then
  log_error(){ echo "[update][ERROR] $*" >&2; }
fi

_notify() {
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "Package Update" "$*"
  else
    log_info "NOTIFY: $*"
  fi
}

# --- Helpers para obter versão ---

_check_git_version() {
  local url="$1"
  git ls-remote --tags "$url" 2>/dev/null \
    | grep -E 'refs/tags' \
    | awk '{print $2}' \
    | sed 's#refs/tags/##' \
    | sort -V | tail -n1
}

_check_http_version() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -sL "$url" | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | sort -V | tail -n1
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$url" | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | sort -V | tail -n1
  else
    echo ""
  fi
}

_check_ftp_version() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -s "$url" | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | sort -V | tail -n1
  else
    echo ""
  fi
}

# --- Função principal ---

update_check_all() {
  log_info "Verificando novas versões em $PORTSDIR"

  for port in "$PORTSDIR"/*; do
    [ -d "$port" ] || continue
    [ -f "$port/Makefile" ] || continue

    local name version src_uri latest
    name=$(make -C "$port" -s -f Makefile -V PORTNAME || basename "$port")
    version=$(make -C "$port" -s -f Makefile -V PORTVERSION || echo "0")
    src_uri=$(make -C "$port" -s -f Makefile -V SRC_URI || echo "")

    [ -z "$src_uri" ] && continue

    log_info "[$name] versão local: $version"

    case "$src_uri" in
      git://*|*.git|ssh://*|https://*.git)
        latest=$(_check_git_version "$src_uri")
        ;;
      http://*|https://*)
        latest=$(_check_http_version "$src_uri")
        ;;
      ftp://*)
        latest=$(_check_ftp_version "$src_uri")
        ;;
      file://*)
        latest=""
        ;;
      *)
        latest=""
        ;;
    esac

    [ -z "$latest" ] && {
      log_warn "[$name] não foi possível determinar versão remota"
      continue
    }

    log_info "[$name] versão remota: $latest"

    if [ "$latest" != "$version" ]; then
      log_info "[$name] Nova versão disponível: $latest"
      echo "{\"name\":\"$name\",\"current\":\"$version\",\"latest\":\"$latest\",\"src\":\"$src_uri\"}" \
        > "$UPDATESDIR/$name.json"
      _notify "$name: nova versão $latest (instalada $version)"
    else
      log_info "[$name] já está atualizado"
    fi
  done
}

# --- Export ---
export -f update_check_all

# Execução direta
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  update_check_all
fi
