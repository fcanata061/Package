#!/usr/bin/env bash
# patch.sh - módulo para aplicar patches em fontes
# Integra-se com build.sh e hooks.sh

set -euo pipefail
IFS=$'\n\t'

MODULE_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
LOG_DIR=${LOG_DIR:-/var/log/package}
PATCH_DIR=${PATCH_DIR:-patches}

mkdir -p "$LOG_DIR"

if ! declare -F log_info >/dev/null 2>&1; then
  log_info(){ echo "[patch][INFO] $*"; }
fi
if ! declare -F log_warn >/dev/null 2>&1; then
  log_warn(){ echo "[patch][WARN] $*"; }
fi
if ! declare -F log_error >/dev/null 2>&1; then
  log_error(){ echo "[patch][ERROR] $*" >&2; }
fi

# Aplica um patch a partir de um arquivo em um diretório de build
# Usage: apply_patch FILE BUILD_DIR
apply_patch(){
  local file="$1" builddir="$2"
  if [ -z "$file" ] || [ -z "$builddir" ]; then
    log_error "apply_patch: uso: apply_patch FILE BUILD_DIR"; return 2
  fi
  if [ ! -f "$file" ]; then
    log_error "Patch não encontrado: $file"; return 1
  fi
  if [ ! -d "$builddir" ]; then
    log_error "Diretório de build não existe: $builddir"; return 1
  fi

  log_info "Aplicando patch: $file"
  (cd "$builddir" && patch -p1 -N -r - < "$file")
}

# Aplica lista de patches (array ou lista de caminhos)
# Usage: apply_patches BUILD_DIR PATCH1 [PATCH2 ...]
apply_patches(){
  local builddir="$1"; shift
  if [ -z "$builddir" ]; then
    log_error "apply_patches: uso: apply_patches BUILD_DIR PATCHES..."; return 2
  fi
  if [ ! -d "$builddir" ]; then
    log_error "Diretório de build não existe: $builddir"; return 1
  fi

  for patch in "$@"; do
    # Se patch for relativo, procurar em PATCH_DIR
    if [ ! -f "$patch" ]; then
      if [ -f "$PATCH_DIR/$patch" ]; then
        patch="$PATCH_DIR/$patch"
      elif [ -f "$MODULE_DIR/../$PATCH_DIR/$patch" ]; then
        patch="$MODULE_DIR/../$PATCH_DIR/$patch"
      fi
    fi
    apply_patch "$patch" "$builddir"
  done
}

# Função de alto nível para build.sh: aplica PATCHES definidos no Makefile/config
# Usage: patch_source BUILD_DIR "${PATCHES[@]}"
patch_source(){
  local builddir="$1"; shift
  local patches=("$@")
  if [ ${#patches[@]} -eq 0 ]; then
    log_info "Nenhum patch definido para aplicar"
    return 0
  fi
  log_info "Aplicando patches em $builddir: ${patches[*]}"
  apply_patches "$builddir" "${patches[@]}"
}

export -f apply_patch apply_patches patch_source
