#!/usr/bin/env bash
# utils.sh - Funções auxiliares para o gerenciador source-based

set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Configuração padrão (pode ser sobrescrita pelo package.conf)
# ---------------------------------------------------------------------------

: "${PORTSDIR:=/usr/ports}"
: "${DISTDIR:=/var/cache/package/distfiles}"
: "${PACKAGES_DIR:=/var/cache/package/packages}"
: "${WORKDIR:=/var/tmp/package/build}"
: "${LOG_DIR:=/var/log/package}"
: "${FILES_DIR:=/var/lib/package/files}"
: "${DB_DIR:=/var/lib/package}"

mkdir -p "$DISTDIR" "$PACKAGES_DIR" "$WORKDIR" "$LOG_DIR" "$FILES_DIR" "$DB_DIR"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log_ts() { date +"%Y-%m-%d %H:%M:%S"; }

log_info()  { echo "[$(log_ts)] [INFO] $*"; }
log_warn()  { echo "[$(log_ts)] [WARN] $*"; }
log_error() { echo "[$(log_ts)] [ERROR] $*" >&2; }
log_debug() { [ "${DEBUG:-0}" = "1" ] && echo "[$(log_ts)] [DEBUG] $*"; }

# ---------------------------------------------------------------------------
# Port helpers
# ---------------------------------------------------------------------------

# Normaliza nome de port (aceita categoria/port ou só port)
normalize_portkey() {
    local port="$1"
    if [[ "$port" == */* ]]; then
        echo "$port"
    elif [ -d "$PORTSDIR/$port" ]; then
        echo "$port"
    else
        # fallback: procurar no tree
        local found
        found=$(find "$PORTSDIR" -maxdepth 2 -type d -name "$port" | head -n1 || true)
        if [ -n "$found" ]; then
            echo "${found#$PORTSDIR/}"
        else
            echo "$port" # devolve mesmo assim
        fi
    fi
}

# Extrai versão de um port (Makefile deve ter VERSION ou PORTVERSION)
get_port_version() {
    local port="$1"
    local makefile="$PORTSDIR/$port/Makefile"
    if [ -f "$makefile" ]; then
        awk '/^(VERSION|PORTVERSION)[ \t]*[?:]?=/ {print $3; exit}' "$makefile" || echo "unknown"
    else
        echo "unknown"
    fi
}

# Gera nome completo port-versão
get_port_fullname() {
    local port="$1"
    local ver
    ver=$(get_port_version "$port")
    echo "$port-$ver"
}

# ---------------------------------------------------------------------------
# File & Checksum helpers
# ---------------------------------------------------------------------------

sha256sum_file() {
    local f="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$f" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$f" | awk '{print $1}'
    else
        openssl dgst -sha256 "$f" | awk '{print $2}'
    fi
}

verify_checksum() {
    local f="$1" expected="$2"
    local actual
    actual=$(sha256sum_file "$f")
    if [ "$actual" = "$expected" ]; then
        log_info "Checksum OK para $f"
        return 0
    else
        log_error "Checksum inválido: esperado $expected, obtido $actual"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Run helpers
# ---------------------------------------------------------------------------

# Executa comando e loga saída
run_cmd() {
    local logfile="$1"; shift
    log_info "Executando: $*"
    {
        echo "==> $(log_ts) [RUN] $*"
        "$@"
    } >>"$logfile" 2>&1
}

# ---------------------------------------------------------------------------
# Locking helpers
# ---------------------------------------------------------------------------

lock_file() {
    local name="$1"
    echo "/var/lock/package.${name}.lock"
}

acquire_lock() {
    local name="$1"
    local lfile
    lfile=$(lock_file "$name")
    exec {lock_fd}>"$lfile"
    flock -n "$lock_fd" || {
        log_error "Não foi possível obter lock: $name"
        exit 1
    }
}

release_lock() {
    local name="$1"
    local lfile
    lfile=$(lock_file "$name")
    rm -f "$lfile" || true
}

# ---------------------------------------------------------------------------
# DB helpers (JSONL append-only)
# ---------------------------------------------------------------------------

db_append() {
    local file="$1"; shift
    mkdir -p "$(dirname "$file")"
    echo "$*" >>"$file"
}

db_read_all() {
    local file="$1"
    [ -f "$file" ] && cat "$file" || true
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------

ensure_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "Este comando precisa ser executado como root"
        exit 1
    fi
}

cleanup_dir() {
    local d="$1"
    rm -rf "$d" && mkdir -p "$d"
}
