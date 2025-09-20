#!/usr/bin/env bash
# package/modules/fetch.sh
# Módulo "fetch" para o gerenciador "package"
# Expondo: cmd_fetch <portdir> [--force]
#
# Funciona quando é "sourced" pelo bin/package (espera que existam
# funções de log como log/info/warn/err). Se estas não existirem,
# usa echo como fallback.

# --- Compatibilidade com funções de log do bin/package ---
_have_func() { command -v "$1" >/dev/null 2>&1; }
_log() {
  if _have_func log; then log "$@"; return; fi
  if _have_func info; then info "$@"; return; fi
  printf '%s\n' "$*"
}
_warn() {
  if _have_func warn; then warn "$@"; return; fi
  printf 'AVISO: %s\n' "$*"
}
_err() {
  if _have_func err; then err "$@"; return; fi
  printf 'ERRO: %s\n' "$*"
}

# Defaults — podem ser sobrescritas pelo ambiente (package.conf)
: "${WORKDIR:=/var/tmp/package-work}"
: "${DISTDIR:=${WORKDIR}/distfiles}"
: "${PORTSDIR:=/usr/ports}"
: "${FORCE:=}"
: "${VERBOSE:=0}"
: "${DOWNLOAD_ATTEMPTS:=3}"

# Utilitários
_mkdirp() { mkdir -p "$1" 2>/dev/null || return 1; }

# downloader com fallback curl -> wget -> ftp -> rsync -> git
_downloader_available() {
  if command -v curl >/dev/null 2>&1; then echo "curl"; return 0; fi
  if command -v wget >/dev/null 2>&1; then echo "wget"; return 0; fi
  echo ""
}

_download_http() {
  local url="$1" dst="$2"
  local dl
  dl=$(_downloader_available) || dl=""
  local rc=1
  if [ -n "$dl" ]; then
    if [ "$dl" = "curl" ]; then
      curl -fL --retry "$DOWNLOAD_ATTEMPTS" -o "$dst" "$url" && rc=0 || rc=$?
    else
      wget --tries="$DOWNLOAD_ATTEMPTS" -O "$dst" "$url" && rc=0 || rc=$?
    fi
  else
    return 10
  fi
  return $rc
}

_download_rsync() {
  local url="$1" dst="$2"
  command -v rsync >/dev/null 2>&1 || return 11
  rsync -av --partial "$url" "$dst"
}

_download_git() {
  local url="$1" dst="$2"
  command -v git >/dev/null 2>&1 || return 12
  # clone into a temporary dir then move to dst
  local tmp; tmp="$(mktemp -d)" || return 13
  git clone --depth 1 "$url" "$tmp" >/dev/null 2>&1 || { rm -rf "$tmp"; return 14; }
  _mkdirp "$(dirname "$dst")" || { rm -rf "$tmp"; return 15; }
  mv "$tmp" "$dst" || { rm -rf "$tmp"; return 16; }
  return 0
}

_copy_local() {
  local src="$1" dst="$2"
  if [ -e "$src" ]; then
    _mkdirp "$(dirname "$dst")" || return 20
    cp -a "$src" "$dst" || return 21
    return 0
  fi
  return 22
}

# detecta e baixa um arquivo usando protocolo adequado
_fetch_one_url_to() {
  local url="$1" dst="$2"
  case "$url" in
    rsync://*|*/::*)  _log "rsync -> $url"; _download_rsync "$url" "$dst" && return 0 || return $? ;;
    git://*|http*://*/*.git|*github.com*:*/*.git) _log "git -> $url"; _download_git "$url" "$dst" && return 0 || return $? ;;
    file://*) localpath="${url#file://}"; _log "copiando local $localpath"; _copy_local "$localpath" "$dst" && return 0 || return $? ;;
    /*) _log "copiando local $url"; _copy_local "$url" "$dst" && return 0 || return $? ;;
    http://*|https://*|ftp://*) _log "http/ftp -> $url"; _download_http "$url" "$dst" && return 0 || return $? ;;
    *) _warn "Protocolo desconhecido para $url"; return 30 ;;
  esac
}

# checksum opcional (sha256)
_verify_sha256() {
  local file="$1" expected="$2"
  [ -z "$expected" ] && return 0
  if command -v sha256sum >/dev/null 2>&1; then
    local sum; sum=$(sha256sum "$file" | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    local sum; sum=$(shasum -a 256 "$file" | awk '{print $1}')
  else
    _warn "Nenhuma ferramenta de checksum disponível; pulando verificação"
    return 0
  fi
  if [ "$sum" != "$expected" ]; then
    _err "Checksum inválido para $file: esperado $expected, obtido $sum"
    return 40
  fi
  return 0
}

# parsing simples do Makefile do port para extrair DISTFILES e MASTER_SITES
# aceita linhas do tipo: DISTFILES= a b c
# e linhas com +=
_parse_port_makefile() {
  local makefile="$1"
  local var name rest line
  DISTFILES=""
  MASTER_SITES=""
  DISTFILES_SHA256=""  # opcional, única hash (simples)
  [ -f "$makefile" ] || return 1
  # unir lines com \ continuations
  local content; content=$(awk '{sub(/\\$/,""); printf "%s ", $0} END{print ""}' "$makefile")
  # extrair DISTFILES
  DISTFILES=$(echo "$content" | sed -n 's/.*DISTFILES[:=+]*[[:space:]]*//p' | awk '{print}')
  # extrair MASTER_SITES
  MASTER_SITES=$(echo "$content" | sed -n 's/.*MASTER_SITES[:=+]*[[:space:]]*//p' | awk '{print}')
  # tentativa simples de obter uma hash chamada DISTFILE_SHA256 ou similar
  DISTFILES_SHA256=$(echo "$content" | sed -n 's/.*DISTFILE_SHA256[:=+]*[[:space:]]*//p' | awk '{print}')
  return 0
}

# Busca e baixa todos os DISTFILES para um port
fetch_sources() {
  local portdir="$1"
  local force_flag="$2"
  [ -n "$force_flag" ] && FORCE=1 || true

  if [ -z "$portdir" ]; then
    _err "Uso: fetch_sources <portdir> [--force]"
    return 2
  fi

  local makefile
  makefile="${portdir}/Makefile"
  if [ ! -f "$makefile" ]; then
    _err "Makefile não encontrado em $portdir"
    return 3
  fi

  _parse_port_makefile "$makefile" || { _err "Erro ao parsear Makefile"; return 4; }

  if [ -z "$DISTFILES" ] || [ -z "$MASTER_SITES" ]; then
    _err "DISTFILES ou MASTER_SITES não definidos no Makefile de $portdir"
    return 5
  fi

  _mkdirp "$DISTDIR" || { _err "Não foi possível criar DISTDIR: $DISTDIR"; return 6; }

  local f site
  for f in $DISTFILES; do
    local dst="$DISTDIR/$f"
    if [ -f "$dst" ] && [ -z "$FORCE" ]; then
      _log "fetch: $f já presente em $dst — pulando"
      continue
    fi

    local success=1
    for site in $MASTER_SITES; do
      # normaliza: garante barra final
      site="${site%/}/"
      local url="${site}${f}"
      _log "Tentando: $url"
      if _fetch_one_url_to "$url" "$dst"; then
        _log "Baixado: $dst"
        success=0
        break
      else
        _warn "Falha em: $url"
        rm -f "$dst" 2>/dev/null || true
      fi
    done

    if [ "$success" -ne 0 ]; then
      _err "Não foi possível baixar $f de nenhum MASTER_SITE"
      return 7
    fi

    # se houver hash única (heurística), verifique
    if [ -n "$DISTFILES_SHA256" ]; then
      _verify_sha256 "$dst" "$DISTFILES_SHA256" || { _err "Checksum falhou para $dst"; return 8; }
    fi
  done

  _log "fetch: todos os arquivos para $(basename "$portdir") OK em $DISTDIR"
  return 0
}

# --- Integração com bin/package: expõe cmd_fetch ---
# bin/package chama cmd_<comando> com argumentos posicionais
cmd_fetch() {
  local target="$1"
  shift || true
  local force_arg=0
  for a in "$@"; do case "$a" in --force|-f) force_arg=1 ;; esac; done
  [ "$force_arg" -eq 1 ] && FORCE=1 || true

  if [ -z "$target" ]; then
    _err "Uso: package fetch <portrelpath|pkgname> [--force]"
    return 2
  fi

  # aceitar tanto "gcc" (no PORTSDIR raiz) quanto caminhos relativos
  local portpath
  if [ -d "$PORTSDIR/$target" ]; then
    portpath="$PORTSDIR/$target"
  elif [ -d "$target" ]; then
    portpath="$target"
  else
    # tentar procurar em subdirs (ex.: lang/gcc)
    if [ -d "$PORTSDIR/lang/$target" ]; then
      portpath="$PORTSDIR/lang/$target"
    else
      # fallback: assume target é um diretório relativo
      portpath="$target"
    fi
  fi

  fetch_sources "$portpath" "$FORCE"
}

# End of fetch module
