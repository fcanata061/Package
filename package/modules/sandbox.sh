#!/usr/bin/env bash
# modules/sandbox.sh
# Sandbox helper for builds/installs (systemd-nspawn | chroot | unshare/proot fallback)
#
# Coloque em /opt/package/modules/sandbox.sh e garanta que o CLI principal faça `source` dos módulos.
#
# Variáveis configuráveis (em /etc/package.conf):
# SANDBOX_BASE=/var/sandbox/package
# SANDBOX_TTL=3600        # tempo (s) padrão para limpeza automática de sandboxes antigas
# SANDBOX_BIND=(/usr /lib /lib64 /bin /sbin /usr/ports /var/cache/package)   # binds padrão
# SANDBOX_KEEP=false      # se true não deleta sandboxes após execução
#
# Funcionalidades:
#  - prepare_sandbox <port>
#  - run_sandbox <port> "<cmd...>" [--nspawn-opts "..."]   (retorna exit code do comando)
#  - cleanup_sandbox <port>
#  - list_sandboxes
#
# Observações:
#  - Requer privilégios root para montar/chroot/nspawn; se executar como usuário normal, tenta usar proot/unshare se disponível.
#  - Integre com build.sh trocando chamadas diretas por: package sandbox run net/httpd "make -C /usr/ports/net/httpd ..."

# ---------- Configurações padrão ----------
SANDBOX_BASE=${SANDBOX_BASE:-/var/sandbox/package}
SANDBOX_TTL=${SANDBOX_TTL:-3600}
SANDBOX_KEEP=${SANDBOX_KEEP:-false}
# binds padrão (pode sobrepor em chamada)
SANDBOX_BIND=(${SANDBOX_BIND[@]:-/usr /lib /lib64 /bin /sbin /usr/ports /var/cache/package /etc/resolv.conf})

# fallbacks de logging se não definidos
: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_debug:=:}"
: "${err:=:}"
if ! declare -F log_info >/dev/null; then log_info(){ echo "[sandbox][INFO] $*"; }; fi
if ! declare -F log_warn >/dev/null; then log_warn(){ echo "[sandbox][WARN] $*"; }; fi
if ! declare -F log_debug >/dev/null; then log_debug(){ [ "${DEBUG:-0}" -eq 1 ] && echo "[sandbox][DEBUG] $*"; }; fi
if ! declare -F err >/dev/null; then err(){ echo "[sandbox][ERROR] $*" >&2; }; fi

# ---------- Helpers ----------
_timestamp() { date +%s; }
_uuid() { printf '%s' "$(date +%s)-$RANDOM"; }

# path helper
sandbox_dir_for() {
  local port="$1"
  echo "$SANDBOX_BASE/$(echo "$port" | tr '/' '_')"
}

# ensure dirs exist
mkdir_p() { mkdir -p "$@" 2>/dev/null || true; }

# ---------- detect backends ----------
has_nspawn() { command -v systemd-nspawn >/dev/null 2>&1; }
has_proot() { command -v proot >/dev/null 2>&1; }
has_unshare() { command -v unshare >/dev/null 2>&1; }

# ---------- prepare minimal FS for chroot ----------
prepare_minfs() {
  local root="$1"
  mkdir_p "$root" || return 1
  # create basic directories
  for d in dev proc sys run tmp etc usr var bin sbin lib lib64; do
    mkdir -p "$root/$d"
  done
  chmod 1777 "$root/tmp" 2>/dev/null || true
}

# bind mounts list: array of "source:target" using host paths
default_bind_mounts_for() {
  local port="$1"; shift
  local binds=()
  for p in "${SANDBOX_BIND[@]}"; do
    # if it's a file (e.g. /etc/resolv.conf) mount file
    if [ -e "$p" ]; then
      binds+=("$p:$p")
    fi
  done
  # mount PREFIX inside sandbox to allow installing into it (makes builds see /usr/local etc)
  binds+=("${PREFIX:-/usr/local}:${PREFIX:-/usr/local}")
  # mount ports tree
  [ -d "${PORTSDIR:-/usr/ports}" ] && binds+=("${PORTSDIR:-/usr/ports}:${PORTSDIR:-/usr/ports}")
  echo "${binds[@]}"
}

# perform bind mounts (idempotent)
_mount_bind() {
  local src="$1" dst="$2"
  mkdir -p "$dst"
  if mountpoint -q "$dst" 2>/dev/null; then
    log_debug "Already mounted: $dst"
    return 0
  fi
  mount --bind "$src" "$dst" || { err "Falha mount --bind $src -> $dst"; return 1; }
  # make ro for safety? keep rw for build
  return 0
}

# ---------- prepare sandbox (create directory + binds) ----------
prepare_sandbox() {
  local port="$1"
  [ -n "$port" ] || { err "prepare_sandbox requer <categoria/port>"; return 2; }
  local base
  base=$(sandbox_dir_for "$port")
  mkdir_p "$base"
  local inst="${base}/instance-$(date +%s)"
  mkdir_p "$inst"
  prepare_minfs "$inst" || return 1

  # setup bind mounts
  local binds
  read -r -a binds <<< "$(default_bind_mounts_for "$port")"
  for map in "${binds[@]}"; do
    local src="${map%%:*}"
    local dst="${map#*:}"
    [ -e "$src" ] || { log_warn "Bind source não existe: $src (pulando)"; continue; }
    mkdir -p "$inst/$dst"
    _mount_bind "$src" "$inst/$dst" || {
      log_warn "Falha ao montar $src em $inst/$dst (continuando)"
    }
  done

  # /dev, /proc, /sys mounts if root
  if [ "$(id -u)" -eq 0 ]; then
    mount --bind /dev "$inst/dev" || true
    mount -t proc proc "$inst/proc" || true
    mount --bind /sys "$inst/sys" || true
  fi

  # record metadata
  echo "created=$(date --iso-8601=seconds 2>/dev/null || date)" > "$inst/.meta"
  echo "port=$port" >> "$inst/.meta"
  log_info "Sandbox preparada: $inst"
  echo "$inst"
}

# ---------- cleanup sandbox ----------
cleanup_sandbox() {
  local port="$1"
  local base insts
  base=$(sandbox_dir_for "$port")
  [ -d "$base" ] || { log_warn "Nenhuma sandbox encontrada para $port"; return 0; }
  # remove all instance directories under base
  for inst in "$base"/instance-*; do
    [ -d "$inst" ] || continue
    log_info "Limpando sandbox: $inst"
    # umount known mounts safely
    if mountpoint -q "$inst/dev" 2>/dev/null; then umount -l "$inst/dev" || true; fi
    if mountpoint -q "$inst/proc" 2>/dev/null; then umount -l "$inst/proc" || true; fi
    if mountpoint -q "$inst/sys" 2>/dev/null; then umount -l "$inst/sys" || true; fi
    # try to unmount other bind mounts (best-effort)
    # iterate mountpoints under inst and unmount
    if [ "$(id -u)" -eq 0 ]; then
      awk "\$2 ~ /^$inst/ {print \$2}" /proc/mounts 2>/dev/null | sort -r | while read -r m; do
        umount -l "$m" 2>/dev/null || true
      done
    fi
    rm -rf "$inst" || log_warn "Falha ao remover $inst"
  done
  # if base empty, remove it
  rmdir "$base" 2>/dev/null || true
  log_info "Cleanup concluído para $port"
  return 0
}

# ---------- run command inside sandbox ----------
# tries in order: systemd-nspawn -> chroot (requires root) -> proot (rootless) -> unshare+pivot (rootless, advanced)
run_in_sandbox() {
  local inst="$1"; shift
  local cmd="$*"
  [ -d "$inst" ] || { err "Instância de sandbox inválida: $inst"; return 2; }

  # detect nspawn
  if has_nspawn && [ "$(id -u)" -eq 0 ]; then
    log_info "Executando via systemd-nspawn: $cmd"
    # keep network isolated by --private-network if desired; allow customization via SANDBOX_NSPAWN_OPTS env
    local nspawn_opts=${SANDBOX_NSPAWN_OPTS:-"--register=yes --setenv=SANDBOX=1"}
    systemd-nspawn -D "$inst" $nspawn_opts -- /bin/bash -lc "$cmd"
    return $?
  fi

  # root + chroot path
  if [ "$(id -u)" -eq 0 ]; then
    log_info "Executando via chroot: $cmd"
    chroot "$inst" /bin/bash -lc "$cmd"
    return $?
  fi

  # try proot
  if has_proot; then
    log_info "Executando via proot (rootless): $cmd"
    proot -R "$inst" /bin/bash -lc "$cmd"
    return $?
  fi

  # try unshare (namespaces) with user mapping - best effort
  if has_unshare; then
    log_info "Executando via unshare (rootless attempt): $cmd"
    # this is best-effort and may fail without proper privileges
    unshare --map-root-user --fork --mount-proc /bin/bash -lc "chroot $inst /bin/bash -lc '$cmd'"
    return $?
  fi

  err "Nenhuma backend de sandbox disponível (systemd-nspawn/chroot/proot/unshare)"
  return 3
}

# ---------- High-level API ----------
# package sandbox run <port> "<cmd>" [--keep] [--nspawn-opts "..."] [--bind "/host:/guest,..."]
cmd_sandbox() {
  local action="$1"; shift || true
  case "$action" in
    prepare)
      local port="$1"
      [ -n "$port" ] || { err "Uso: package sandbox prepare <categoria/port>"; return 2; }
      prepare_sandbox "$port" >/dev/null || return 1
      ;;
    run)
      local port="$1"; shift || true
      local rawcmd="$1"; shift || true
      [ -n "$port" ] || { err "Uso: package sandbox run <categoria/port> \"<cmd>\""; return 2; }
      [ -n "$rawcmd" ] || { err "Comando não informado"; return 2; }

      # optional args parsing (simple)
      local keep=false
      while [ $# -gt 0 ]; do
        case "$1" in
          --keep) keep=true; shift ;;
          --nspawn-opts) SANDBOX_NSPAWN_OPTS="$2"; shift 2 ;;
          --bind) IFS=',' read -r -a extra_binds <<< "$2"; shift 2 ;;
          *) shift ;;
        esac
      done

      local inst
      inst=$(prepare_sandbox "$port") || return 1

      # apply extra binds if provided
      if [ -n "${extra_binds[*]:-}" ]; then
        for mp in "${extra_binds[@]}"; do
          local s="${mp%%:*}" d="${mp#*:}"
          mkdir -p "$inst/$d"
          _mount_bind "$s" "$inst/$d" || log_warn "Falha bind extra $s -> $inst/$d"
        done
      fi

      # trap cleanup on exit (unless keep)
      local cleanup_on_exit=true
      if [ "$keep" = true ] || [ "$SANDBOX_KEEP" = true ]; then cleanup_on_exit=false; fi
      (
        # subshell to run command; capture status
        set -o pipefail
        run_in_sandbox "$inst" "$rawcmd"
      )
      local rc=$?
      if [ "$cleanup_on_exit" = true ]; then
        # best effort cleanup
        if [ "$(id -u)" -eq 0 ]; then
          # attempt unmounts of known mounts under inst
          awk "\$2 ~ /^$inst/ {print \$2}" /proc/mounts 2>/dev/null | sort -r | while read -r m; do
            umount -l "$m" 2>/dev/null || true
          done
        fi
        rm -rf "$inst" 2>/dev/null || log_warn "Falha ao remover sandbox $inst"
      else
        log_info "Sandbox preservada: $inst"
      fi
      return $rc
      ;;
    cleanup)
      local port="$1"
      [ -n "$port" ] || { err "Uso: package sandbox cleanup <categoria/port>"; return 2; }
      cleanup_sandbox "$port"
      ;;
    list)
      # list sandboxes
      local base inst
      base="$SANDBOX_BASE"
      [ -d "$base" ] || { echo "Nenhuma sandbox"; return 0; }
      for inst in "$base"/*; do
        [ -d "$inst" ] || continue
        echo "$inst:"
        [ -f "$inst/.meta" ] && sed -n '1,5p' "$inst/.meta"
        echo
      done
      ;;
    prune-old)
      # remove sandboxes older than SANDBOX_TTL
      local now ts
      now=$(_timestamp)
      for inst in "$SANDBOX_BASE"/*/instance-* 2>/dev/null; do
        [ -d "$inst" ] || continue
        ts=$(stat -c %Y "$inst" 2>/dev/null || stat -f %m "$inst" 2>/dev/null)
        if [ -n "$ts" ] && [ $((now - ts)) -gt "$SANDBOX_TTL" ]; then
          log_info "Prunando sandbox antiga: $inst"
          cleanup_sandbox "$(basename "$(dirname "$inst")")" || true
        fi
      done
      ;;
    *)
      echo "Uso: package sandbox <prepare|run|cleanup|list|prune-old>"
      return 2
      ;;
  esac
}

# expose helper functions if sourced
export -f prepare_sandbox cleanup_sandbox run_in_sandbox prepare_minfs sandbox_dir_for
# fim do módulo
