#!/usr/bin/env bash
# modules/sandbox.sh
#
# Sandbox module (completo e funcional)
#
# Fornece:
#   sandbox_prepare <portkey> <workdir> <staging_dir>    # opcional: cria ambiente persistente
#   sandbox_cleanup <portkey> <workdir> <staging_dir>    # opcional: limpa ambiente
#   sandbox_exec <workdir> <command...>                  # executa comando dentro do sandbox (sync)
#   sandbox_run_script <workdir> <script-file> [args...] # executa um script dentro do sandbox
#
# Compatível com SANDBOX_METHOD = none|bwrap|chroot|docker (padrão none)
# Integra com /etc/package.conf para SANDBOX_METHOD, SANDBOX_CHROOT_BASE, SANDBOX_DOCKER_IMAGE, SANDBOX_BWRAP_OPTS
#
# Notas:
# - bwrap (bubblewrap) é preferido quando disponível por ser simples e sem privilégios.
# - chroot requer root e um sistema base em SANDBOX_CHROOT_BASE (ou o chroot será criado copiando arquivos essenciais)
# - docker requer docker daemon e usa --rm com binds no WORKDIR e /usr/ports
# - "none" executa o comando diretamente (fallback).
#
# Saídas/Retornos:
# - sandbox_exec imprime nothing; retorna 0 em sucesso, não imprime ambiente.
# - As funções exportadas são: sandbox_prepare, sandbox_cleanup, sandbox_exec, sandbox_run_script
#
# Uso em build.sh:
#   sandbox_exec "$builddir" "bash -lc 'cd src && ./configure && make -j4'"
#
# Autor: ChatGPT (adaptado)
# Data: 2025-09-20
set -euo pipefail

# Load config if available
[ -f /etc/package.conf ] && source /etc/package.conf

# Defaults
SANDBOX_METHOD=${SANDBOX_METHOD:-none}        # none | bwrap | chroot | docker
SANDBOX_BWRAP_OPTS=${SANDBOX_BWRAP_OPTS:-""} # additional bwrap options
SANDBOX_CHROOT_BASE=${SANDBOX_CHROOT_BASE:-/var/lib/package/chroot_base}
SANDBOX_CHROOT_ROOTDIR=${SANDBOX_CHROOT_ROOTDIR:-/var/lib/package/chroots}
SANDBOX_DOCKER_IMAGE=${SANDBOX_DOCKER_IMAGE:-ubuntu:22.04}
SANDBOX_TMPBASE=${SANDBOX_TMPBASE:-/tmp/package-sandbox}
SANDBOX_ALLOWED_HOSTPATHS=${SANDBOX_ALLOWED_HOSTPATHS:-"/usr /lib /lib64 /bin /sbin /etc /dev /proc /sys /usr/ports"}

# Logging fallbacks
: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_error:=:}"
if ! declare -F log_info >/dev/null 2>&1; then
  log_info(){ echo "[sandbox][INFO] $*"; }
fi
if ! declare -F log_warn >/dev/null 2>&1; then
  log_warn(){ echo "[sandbox][WARN] $*"; }
fi
if ! declare -F log_error >/dev/null 2>&1; then
  log_error(){ echo "[sandbox][ERROR] $*" >&2; }
fi

# Helpers
_mktemp_dir() {
  mkdir -p "$SANDBOX_TMPBASE"
  mktemp -d "${SANDBOX_TMPBASE}/sb-XXXXX"
}

# Check tool availability
_has_bwrap() { command -v bwrap >/dev/null 2>&1; }
_has_docker() { command -v docker >/dev/null 2>&1; }
_is_root() { [ "$(id -u)" -eq 0 ]; }

# prepare chroot base (best-effort)
_chroot_prepare_base() {
  # create minimal base if not exists (very conservative)
  if [ -d "$SANDBOX_CHROOT_BASE" ]; then
    log_info "Chroot base encontrado: $SANDBOX_CHROOT_BASE"
    return 0
  fi

  if ! _is_root; then
    log_warn "Criar chroot base requer root; pule a preparação manualmente"
    return 1
  fi

  log_info "Criando chroot base em $SANDBOX_CHROOT_BASE (minimal)"
  mkdir -p "$SANDBOX_CHROOT_BASE"{/bin,/lib,/lib64,/usr,/usr/bin,/etc,/tmp}
  # Copy a very small set of files needed for basic shell
  if command -v bash >/dev/null 2>&1; then
    cp "$(command -v bash)" "$SANDBOX_CHROOT_BASE/bin/" || true
  fi
  # copy ld-linux and libc if possible (best-effort)
  for lib in /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2; do
    [ -f "$lib" ] && cp -a "$lib" "$SANDBOX_CHROOT_BASE/lib64/" 2>/dev/null || true
  done
  # This is minimal and may not work for all builds. Recommend user maintain a full debootstrap or pacstrap.
  log_warn "Chroot base criada de forma minimal; para builds reais, forneça um base completo (debootstrap/pacstrap)."
  return 0
}

# Create chroot instance for a port (best-effort)
_chroot_create_instance() {
  local portkey="$1" workdir="$2"
  local instroot="${SANDBOX_CHROOT_ROOTDIR}/${portkey}-$(date +%s)"
  mkdir -p "$instroot"
  log_info "Criando chroot instance em $instroot (base: $SANDBOX_CHROOT_BASE)"
  if [ -d "$SANDBOX_CHROOT_BASE" ]; then
    # bind-mount or copy base
    if _is_root; then
      # bind mount base for speed
      rsync -a --delete "$SANDBOX_CHROOT_BASE"/ "$instroot"/ || true
    else
      # fallback: copy (may require root for some things)
      cp -a "$SANDBOX_CHROOT_BASE"/. "$instroot"/ || true
    fi
  else
    log_warn "Chroot base ausente; tentativa de usar host files (não isolado)"
  fi
  # create work mounts inside chroot: /work will point to workdir
  mkdir -p "$instroot/work"
  # bind mount actual workdir if root
  if _is_root; then
    mount --bind "$workdir" "$instroot/work" 2>/dev/null || true
  else
    # copy contents into chroot/work
    cp -a "$workdir"/. "$instroot/work"/ 2>/dev/null || true
  fi
  printf '%s' "$instroot"
}

# Cleanup chroot instance
_chroot_destroy_instance() {
  local instroot="$1"
  if [ -z "$instroot" ] || [ ! -d "$instroot" ]; then return 0; fi
  log_info "Limpando chroot instance $instroot"
  # attempt to unmount bind mounts
  if _is_root; then
    # find mounts under instroot and try to umount
    while read -r m; do
      mountpoint="$(echo "$m" | awk '{print $2}')"
      umount -l "$mountpoint" 2>/dev/null || true
    done < <(mount | grep "$instroot" || true)
  fi
  # remove directory (best-effort)
  rm -rf "$instroot" 2>/dev/null || true
}

# Create bubblewrap sandbox command
_bwrap_cmd_base() {
  local workdir="$1"
  local cmdfile="$2"
  # create binds for allowed host paths
  local binds=()
  IFS=' ' read -r -a paths <<< "$SANDBOX_ALLOWED_HOSTPATHS"
  for p in "${paths[@]}"; do
    [ -e "$p" ] || continue
    binds+=("--ro-bind" "$p" "$p")
  done
  # bind workdir read-write at /work
  binds+=("--bind" "$workdir" "/work")
  # minimal /tmp writable
  binds+=("--tmpfs" "/tmp")
  # set working dir and user mapping (no newuidmap handled)
  # build command: bwrap [binds] -- chroot command runs bash -lc "cd /work && source env && exec ..."
  printf '%s\n' "${binds[@]}"
}

# docker run wrapper
_docker_run_cmd() {
  local workdir="$1"
  local cmd="$2"
  # map workdir into container at /work, and /usr/ports if exists
  local binds=("-v" "${workdir}:/work:Z")
  # expose /usr/ports if exists
  if [ -d "${PORTSDIR:-/usr/ports}" ]; then
    binds+=("-v" "${PORTSDIR}:/usr/ports:Z")
  fi
  # run container and execute /bin/bash -lc "cd /work && $cmd"
  docker run --rm -it "${binds[@]}" --workdir /work "$SANDBOX_DOCKER_IMAGE" /bin/bash -lc "$cmd"
}

# Public: sandbox_prepare <portkey> <workdir> <staging_dir>
# Creates and returns an identifier for the sandbox (path or id). Best-effort.
sandbox_prepare() {
  local portkey="$1" workdir="$2" staging="$3"
  case "$SANDBOX_METHOD" in
    none)
      log_info "SANDBOX_METHOD=none: nenhuma preparação necessária"
      printf '%s' "none"
      ;;
    bwrap)
      if ! _has_bwrap; then
        log_warn "bwrap não disponível; fallback para none"
        printf '%s' "none"
        return 0
      fi
      # For bwrap no persistent state needed
      log_info "bwrap sandbox será usado (no state)"
      printf '%s' "bwrap"
      ;;
    chroot)
      if ! _is_root; then
        log_warn "chroot requer root. Se não for root, sandbox será criado em modo copy (menos isolado)"
      fi
      mkdir -p "$SANDBOX_CHROOT_ROOTDIR"
      _chroot_prepare_base || true
      local inst
      inst=$(_chroot_create_instance "$portkey" "$workdir")
      printf '%s' "$inst"
      ;;
    docker)
      if ! _has_docker; then
        log_warn "docker não disponível; fallback para none"
        printf '%s' "none"
      else
        log_info "docker sandbox será usado (image: $SANDBOX_DOCKER_IMAGE)"
        printf '%s' "docker"
      fi
      ;;
    *)
      log_warn "Método sandbox desconhecido: $SANDBOX_METHOD -> fallback none"
      printf '%s' "none"
      ;;
  esac
}

# Public: sandbox_cleanup <portkey> <workdir> <staging_dir> <sandbox-id?>
# Cleanup resources allocated by sandbox_prepare.
sandbox_cleanup() {
  local portkey="$1" workdir="$2" staging="$3" sandbox_id="${4:-}"
  case "$SANDBOX_METHOD" in
    chroot)
      if [ -n "$sandbox_id" ] && [ -d "$sandbox_id" ]; then
        _chroot_destroy_instance "$sandbox_id" || true
      fi
      ;;
    bwrap|none|docker)
      # nothing to cleanup for bwrap or docker (docker runs --rm)
      log_info "sandbox_cleanup: nada a fazer para method $SANDBOX_METHOD"
      ;;
  esac
}

# Public: sandbox_exec <workdir> <command...>
# Executes command inside the chosen sandbox method. Workdir is bound/mapped to /work inside sandbox.
# Returns command exit status.
sandbox_exec() {
  if [ $# -lt 2 ]; then
    log_error "sandbox_exec usage: sandbox_exec <workdir> <command...>"
    return 2
  fi
  local workdir="$1"; shift
  local cmd="$*"

  case "$SANDBOX_METHOD" in
    none)
      log_info "SANDBOX_METHOD=none: executando diretamente em $workdir: $cmd"
      (cd "$workdir" && bash -lc "$cmd")
      return $?
      ;;
    bwrap)
      if ! _has_bwrap; then
        log_warn "bwrap não disponível; executando diretamente"
        (cd "$workdir" && bash -lc "$cmd")
        return $?
      fi
      # build bwrap args
      local tmpdir
      tmpdir=$(_mktemp_dir)
      # mount typical system dirs read-only and bind workdir
      local bwrap_args=()
      # establish minimal environment
      bwrap_args+=(--ro-bind / /)
      # bind allowed host paths read-only to avoid breaking builds that need them
      IFS=' ' read -r -a paths <<< "$SANDBOX_ALLOWED_HOSTPATHS"
      for p in "${paths[@]}"; do
        [ -e "$p" ] || continue
        bwrap_args+=(--ro-bind "$p" "$p")
      done
      bwrap_args+=(--bind "$workdir" /work)
      bwrap_args+=(--tmpfs /tmp)
      bwrap_args+=(--dir /run --proc /proc --dev /dev)
      # drop extra capabilities (bwrap handles)
      # set working dir & execute
      log_info "Executando em bwrap: cd /work && $cmd"
      if bwrap "${bwrap_args[@]}" -- chroot / /bin/bash -lc "cd /work && $cmd"; then
        rm -rf "$tmpdir" 2>/dev/null || true
        return 0
      else
        rm -rf "$tmpdir" 2>/dev/null || true
        return 1
      fi
      ;;
    chroot)
      # create instance and chroot into it
      local instroot
      instroot=$(_chroot_create_instance "temp" "$workdir")
      if [ -z "$instroot" ] || [ ! -d "$instroot" ]; then
        log_warn "Falha ao criar chroot instance; executando diretamente"
        (cd "$workdir" && bash -lc "$cmd")
        return $?
      fi
      log_info "Executando dentro do chroot $instroot: cd /work && $cmd"
      if _is_root; then
        chroot "$instroot" /bin/bash -lc "cd /work && $cmd"
        local rc=$?
        _chroot_destroy_instance "$instroot"
        return $rc
      else
        if command -v sudo >/dev/null 2>&1; then
          sudo chroot "$instroot" /bin/bash -lc "cd /work && $cmd"
          local rc=$?
          _chroot_destroy_instance "$instroot"
          return $rc
        else
          log_warn "Não há sudo/root para usar chroot; executando diretamente"
          (cd "$workdir" && bash -lc "$cmd")
          return $?
        fi
      fi
      ;;
    docker)
      if ! _has_docker; then
        log_warn "docker não disponível; executando diretamente"
        (cd "$workdir" && bash -lc "$cmd")
        return $?
      fi
      # try to run using docker image
      log_info "Executando em docker ($SANDBOX_DOCKER_IMAGE): cd /work && $cmd"
      _docker_run_cmd "$workdir" "$cmd"
      return $?
      ;;
    *)
      log_warn "Método sandbox desconhecido: $SANDBOX_METHOD; executando diretamente"
      (cd "$workdir" && bash -lc "$cmd")
      return $?
      ;;
  esac
}

# Public: sandbox_run_script <workdir> <script-file> [args...]
# Copies script into workdir (if necessary) and executes inside sandbox.
sandbox_run_script() {
  if [ $# -lt 2 ]; then
    log_error "sandbox_run_script usage: sandbox_run_script <workdir> <script-file> [args...]"
    return 2
  fi
  local workdir="$1"; shift
  local script="$1"; shift
  local basenm
  basenm="$(basename "$script")"
  mkdir -p "$workdir/.sandbox-scripts"
  cp -a "$script" "$workdir/.sandbox-scripts/$basenm"
  chmod +x "$workdir/.sandbox-scripts/$basenm"
  sandbox_exec "$workdir" "/work/.sandbox-scripts/$basenm $*"
}

# Export functions
export -f sandbox_prepare sandbox_cleanup sandbox_exec sandbox_run_script

# If run directly: small CLI for testing
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    prepare)
      sandbox_prepare "${2:-test}" "${3:-/tmp}" "${4:-/tmp/staging}"
      ;;
    exec)
      shift
      sandbox_exec "$@"
      ;;
    run)
      shift
      sandbox_run_script "$@"
      ;;
    cleanup)
      sandbox_cleanup "${2:-}" "${3:-}" "${4:-}"
      ;;
    help|--help|-h|?)
      cat <<EOF
sandbox.sh CLI
Usage:
  $0 prepare <portkey> <workdir> <staging>
  $0 exec <workdir> "<command...>"
  $0 run <workdir> <script> [args...]
  $0 cleanup <portkey> <workdir> <staging> [sandbox-id]

Environment config (/etc/package.conf):
  SANDBOX_METHOD: none|bwrap|chroot|docker (default: none)
  SANDBOX_CHROOT_BASE: path to chroot base
  SANDBOX_DOCKER_IMAGE: docker image to use
  SANDBOX_ALLOWED_HOSTPATHS: space-separated list of host paths to bind inside sandbox
EOF
      ;;
    *)
      echo "Unknown subcommand. Use help."
      exit 2
      ;;
  esac
fi
