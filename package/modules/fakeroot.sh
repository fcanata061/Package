#!/usr/bin/env bash
# fakeroot.sh - módulo para empacotar e instalar staging usando fakeroot
# Fornece funções:
# - create_package_from_staging STAGING OUT_TARBALL
# - fakeroot_install_from_staging STAGING PORTKEY
# - install_package PACKAGE_PATH

set -euo pipefail
IFS=$'\n\t'

MODULE_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
LOG_DIR=${LOG_DIR:-/var/log/package}
PACKAGES_DIR=${PACKAGES_DIR:-/var/cache/package/packages}
REAL_INSTALL=${REAL_INSTALL:-no}   # if yes, attempt to install to system using sudo/rsync

mkdir -p "$LOG_DIR" "$PACKAGES_DIR"

if ! declare -F log_info >/dev/null 2>&1; then
  log_info(){ echo "[fakeroot][INFO] $*"; }
fi
if ! declare -F log_warn >/dev/null 2>&1; then
  log_warn(){ echo "[fakeroot][WARN] $*"; }
fi
if ! declare -F log_error >/dev/null 2>&1; then
  log_error(){ echo "[fakeroot][ERROR] $*" >&2; }
fi

# Verifica se fakeroot está disponível
_check_fakeroot(){
  if command -v fakeroot >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# Cria um tarball (gzip) do staging preservando metadata (perm/uid/gid) usando fakeroot
# Usage: create_package_from_staging /path/to/staging /path/to/out.tar.gz
create_package_from_staging(){
  local staging="$1" out="$2"
  if [ -z "$staging" ] || [ -z "$out" ]; then
    log_error "create_package_from_staging: uso: create_package_from_staging STAGING OUT_TARBALL"; return 2
  fi
  if [ ! -d "$staging" ]; then
    log_error "Staging não existe: $staging"; return 1
  fi
  mkdir -p "$(dirname "$out")"
  if _check_fakeroot; then
    log_info "Criando tarball de pacote com fakeroot: $out"
    fakeroot sh -c "cd '$staging' && tar --numeric-owner -cpf - ." | gzip -9 > "$out"
    log_info "Pacote criado: $out"
    return 0
  else
    log_warn "fakeroot não disponível; criando tarball sem fakeroot (perms/owners poderão variar)"
    (cd "$staging" && tar -cpf - .) | gzip -9 > "$out"
    log_info "Pacote criado (sem fakeroot): $out"
    return 0
  fi
}

# Instala staging no sistema. Comportamento:
# - se REAL_INSTALL=yes tentamos aplicar ao sistema com sudo rsync (requer senha)
# - caso contrário, empacotamos o staging em PACKAGES_DIR e retornamos o caminho
# Usage: fakeroot_install_from_staging /path/to/staging portkey
fakeroot_install_from_staging(){
  local staging="$1" portkey="$2"
  if [ -z "$staging" ] || [ -z "$portkey" ]; then
    log_error "fakeroot_install_from_staging: uso: fakeroot_install_from_staging STAGING PORTKEY"; return 2
  fi
  if [ ! -d "$staging" ]; then
    log_error "staging não existe: $staging"; return 1
  fi

  local ts=$(date +%Y%m%d%H%M%S)
  local pkgname="${portkey}-${ts}.tar.gz"
  local pkgpath="$PACKAGES_DIR/$pkgname"

  if [ "$REAL_INSTALL" = "yes" ]; then
    log_info "REAL_INSTALL=yes: aplicando staging diretamente no sistema (requer sudo)"
    if command -v rsync >/dev/null 2>&1; then
      if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
          log_info "Usando sudo rsync para copiar arquivos para /"
          sudo rsync -a --no-o --no-g "$staging"/ / || { log_error "sudo rsync falhou"; return 1; }
          log_info "Instalação direta concluída via rsync"
          return 0
        else
          log_error "REAL_INSTALL requerido mas sudo não disponível"
          return 1
        fi
      else
        rsync -a "$staging"/ / || { log_error "rsync falhou"; return 1; }
        log_info "Instalação direta concluída (root)"
        return 0
      fi
    else
      log_error "rsync não disponível; não é possível instalar diretamente"
      return 1
    fi
  fi

  # Caso padrão: empacotar em PACKAGES_DIR usando fakeroot para preservar metadados
  create_package_from_staging "$staging" "$pkgpath" || { log_error "Falha ao criar pacote"; return 1; }
  log_info "Pacote gerado em: $pkgpath"
  # Também gerar um índice simples
  echo "$pkgpath" >> "$PACKAGES_DIR/INDEX" || true
  echo "$pkgpath"
  return 0
}

# Instala um pacote .tar.gz gerado por create_package_from_staging
# Usage: install_package /path/to/pkg.tar.gz
install_package(){
  local pkg="$1"
  if [ -z "$pkg" ]; then
    log_error "install_package: uso: install_package PACKAGE_PATH"; return 2
  fi
  if [ ! -f "$pkg" ]; then
    log_error "Pacote não encontrado: $pkg"; return 1
  fi
  log_info "Instalando pacote: $pkg"
  if [ "$(id -u)" -eq 0 ]; then
    gzip -dc "$pkg" | tar --numeric-owner -xpf - -C / || { log_error "tar falhou"; return 1; }
    log_info "Instalação concluída (root)"
    return 0
  fi
  # Se não root, tentar sudo tar
  if command -v sudo >/dev/null 2>&1; then
    gzip -dc "$pkg" | sudo tar --numeric-owner -xpf - -C / || { log_error "sudo tar falhou"; return 1; }
    log_info "Instalação concluída via sudo"
    return 0
  fi
  log_error "Não é root e sudo não disponível — não é possível instalar pacote"
  return 1
}

export -f create_package_from_staging fakeroot_install_from_staging install_package
