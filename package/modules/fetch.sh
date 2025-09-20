#!/usr/bin/env bash
# modules/fetch.sh
# modules/fetch.sh (evoluído, completo e funcional)
#
# Responsável por baixar as fontes (DISTFILE/DISTFILES) ou clonar fontes VCS.
# Integra com: PORTSDIR, CACHE_DIR, log_info/log_warn/log_error, MAKEFILE variables.
#
# Exporta: cmd_fetch <categoria/port> [--force|--no-verify|--list-only]
#
# Principais variáveis (podem ser sobrescritas em /etc/package.conf):
#   PORTSDIR (default /usr/ports)
#   CACHE_DIR (default /var/cache/package)
#   FETCH_TIMEOUT (default 30)
#   FETCH_RETRIES (default 3)

PORTSDIR=${PORTSDIR:-/usr/ports}
CACHE_DIR=${CACHE_DIR:-/var/cache/package}
FETCH_TIMEOUT=${FETCH_TIMEOUT:-30}
FETCH_RETRIES=${FETCH_RETRIES:-3}
USER_AGENT=${USER_AGENT:-"package-fetch/1.0"}

mkdir -p "$CACHE_DIR"

# logging fallbacks (integra com modules/logs.sh)
: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_error:=:}"
if ! declare -F log_info >/dev/null; then log_info(){ echo "[fetch][INFO] $*"; }; fi
if ! declare -F log_warn >/dev/null; then log_warn(){ echo "[fetch][WARN] $*"; }; fi
if ! declare -F log_error >/dev/null; then log_error(){ echo "[fetch][ERROR] $*" >&2; }; fi

# Helper: read variable from port Makefile (supports continuations with \)
_makefile_var() {
  local port="$1" var="$2"
  local mf="$PORTSDIR/$port/Makefile"
  [ -f "$mf" ] || return 1
  awk -v v="$var" '
    $0 ~ "^[[:space:]]*"v"[[:space:]]*=" {
      sub("^[[:space:]]*"v"[[:space:]]*=","");
      val=$0;
      while (val ~ /\\$/) {
        sub(/\\$/,"",val);
        if (getline nx) val = val nx; else break;
      }
      gsub(/^[[:space:]]+/,"",val);
      gsub(/[[:space:]]+$/,"",val);
      print val;
    }' "$mf" | sed 's/#.*//'
}

# Tokeniza uma lista de DISTFILES (separados por espaço)
_tokenize_list() {
  local s="$*"
  for t in $s; do printf '%s\n' "$t"; done
}

# decide qual downloader usar (wget ou curl)
_have_wget() { command -v wget >/dev/null 2>&1; }
_have_curl() { command -v curl >/dev/null 2>&1; }

# baixa uma única URL para destino (continua, retries)
_download_url() {
  local url="$1" out="$2"
  local retries=${3:-$FETCH_RETRIES}
  if [ -f "$out" ]; then
    log_info "Arquivo já existe no cache: $out"
    return 0
  fi

  for attempt in $(seq 1 $retries); do
    log_info "Baixando ($attempt/$retries): $url -> $out"
    if _have_wget; then
      wget --timeout="$FETCH_TIMEOUT" --tries=2 --user-agent="$USER_AGENT" -c -O "$out.part" "$url" && mv -f "$out.part" "$out" && return 0
    elif _have_curl; then
      curl --fail --location --user-agent "$USER_AGENT" --max-time "$FETCH_TIMEOUT" --retry 2 --output "$out.part" "$url" && mv -f "$out.part" "$out" && return 0
    else
      log_error "Nenhum downloader disponível (wget/curl). Instale um deles."
      return 4
    fi
    log_warn "Falha no download: $url (tentativa $attempt)"
    sleep 1
  done

  log_error "Falha ao baixar $url depois de $retries tentativas"
  rm -f "$out.part" 2>/dev/null || true
  return 5
}

# verifica checksum SHA256 (aceita variável DIST_SHA256 ou SHA256)
_verify_sha256() {
  local file="$1" expected="$2"
  [ -f "$file" ] || return 2
  if [ -z "$expected" ]; then
    log_warn "Sem checksum SHA256 informado para $file"
    return 3
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    local got; got=$(sha256sum "$file" | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    local got; got=$(shasum -a 256 "$file" | awk '{print $1}')
  else
    log_warn "Nenhuma ferramenta de checksum (sha256sum/shasum) disponível — pulando verificação"
    return 0
  fi

  if [ "$got" = "$expected" ]; then
    log_info "Checksum SHA256 OK para $(basename "$file")"
    return 0
  else
    log_error "Checksum mismatch para $(basename "$file"): esperado=$expected got=$got"
    return 1
  fi
}

# Handle VCS sources: git, svn
fetch_vcs() {
  local port="$1" outdir="$2" force="${3:-0}"
  local gitrepo gitref svnrepo
  gitrepo=$(_makefile_var "$port" "GIT_REPOSITORY" 2>/dev/null || true)
  svnrepo=$(_makefile_var "$port" "SVN_REPOSITORY" 2>/dev/null || true)

  if [ -n "$gitrepo" ]; then
    local gitdir="$outdir/$(basename "$gitrepo" .git)"
    if [ -d "$gitdir/.git" ] && [ "$force" -ne 1 ]; then
      log_info "Reusing existing git clone: $gitdir"
      (cd "$gitdir" && git fetch --all --prune) || log_warn "Falha em git fetch (continuando)"
      return 0
    fi
    log_info "Clonando git: $gitrepo -> $gitdir"
    git clone --depth 1 "$gitrepo" "$gitdir" || return 1
    local gref; gref=$(_makefile_var "$port" "GIT_TAG" 2>/dev/null || true)
    [ -n "$gref" ] && (cd "$gitdir" && git checkout "$gref") || true
    return 0
  fi

  if [ -n "$svnrepo" ]; then
    local svndir="$outdir/$(basename "$svnrepo")"
    if [ -d "$svndir/.svn" ] && [ "$force" -ne 1 ]; then
      log_info "Atualizando checkout SVN: $svndir"
      (cd "$svndir" && svn update) || log_warn "Falha em svn update (continuando)"
      return 0
    fi
    log_info "Checkout SVN: $svnrepo -> $svndir"
    svn checkout "$svnrepo" "$svndir" || return 1
    return 0
  fi

  return 2
}

# fetch_one: baixa e verifica um distfile (tenta MASTER_SITES se for relativo)
# argumentos: <port> <distfile-token> <force(0|1)> <no_verify(0|1)>
fetch_one() {
  local port="$1" token="$2" force="${3:-0}" no_verify="${4:-0}"
  local cache="$CACHE_DIR"
  mkdir -p "$cache"

  # normalize token (token pode ser 'file.tar.gz' ou URL)
  local url candidate outpath fname
  fname=$(basename "$token")
  outpath="$cache/$fname"

  # se token already looks like URL (http, ftp)
  if [[ "$token" =~ ^(https?|ftp):// ]]; then
    url="$token"
    if [ ! -f "$outpath" ] || [ "$force" -eq 1 ]; then
      _download_url "$url" "$outpath" || return $?
    else
      log_info "Usando cache para $fname"
    fi
  else
    # token is relative filename: try MASTER_SITES + token
    local masters ms site
    masters=$(_makefile_var "$port" "MASTER_SITES" 2>/dev/null || true)
    if [ -z "$masters" ]; then
      # try DISTFILE variable containing full URL
      local df; df=$(_makefile_var "$port" "DISTFILE" 2>/dev/null || true)
      if [[ "$df" =~ ^(https?|ftp):// ]]; then
        url="$df"
        _download_url "$url" "$outpath" || return $?
      else
        log_error "Não há MASTER_SITES nem DISTFILE URL para resolver $token no port $port"
        return 4
      fi
    else
      # iterate masters until download succeeds
      local success=1
      for site in $masters; do
        # ensure site ends with /
        [[ "$site" =~ /$ ]] || site="$site/"
        url="${site}${token}"
        _download_url "$url" "$outpath" && { success=0; break; }
      done
      [ $success -eq 0 ] || return 5
    fi
  fi

  # checksum verification: try to find SHA256 (DIST_SHA256 or SHA256 or DISTFILES_SHA256)
  local sha256
  sha256=$(_makefile_var "$port" "DIST_SHA256" 2>/dev/null || true)
  [ -z "$sha256" ] && sha256=$(_makefile_var "$port" "SHA256" 2>/dev/null || true)
  # if multiple checksums exist, try to match by filename (simple heuristics)
  if [ -z "$sha256" ]; then
    # try variable named like SHA256_<FILENAME> or DISTFILES_* not standardized -> skip
    true
  fi

  if [ "$no_verify" -eq 1 ]; then
    log_info "Verificação de checksum desativada (--no-verify)"
  else
    if [ -n "$sha256" ]; then
      _verify_sha256 "$outpath" "$sha256" || {
        log_error "Checksum falhou para $outpath"
        return 6
      }
    else
      log_warn "Nenhum checksum SHA256 encontrado para $token (pulando verificação)"
    fi
  fi

  printf '%s\n' "$outpath"
  return 0
}

# cmd_fetch: interface principal
# usage: cmd_fetch <categoria/port> [--force] [--no-verify] [--list-only]
cmd_fetch() {
  local port="$1"; shift || true
  [ -n "$port" ] || { err "fetch requer port (ex: net/httpd)"; return 2; }

  local force=0 no_verify=0 list_only=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      --no-verify) no_verify=1; shift ;;
      --list-only) list_only=1; shift ;;
      *) shift ;;
    esac
  done

  local portdir="$PORTSDIR/$port"
  [ -d "$portdir" ] || { log_error "Port não encontrado: $portdir"; return 3; }

  # VCS first
  if fetch_vcs "$port" "$CACHE_DIR" "$force" == 0 2>/dev/null; then
    log_info "Fonte VCS tratada para $port"
    [ $list_only -eq 1 ] && return 0
    return 0
  fi

  # gather DISTFILES/DISTFILE
  local df df_list
  df=$(_makefile_var "$port" "DISTFILE" 2>/dev/null || true)
  df_list=$(_makefile_var "$port" "DISTFILES" 2>/dev/null || true)
  # if DISTFILES empty but DISTFILE present, use it
  if [ -z "$df_list" ] && [ -n "$df" ]; then df_list="$df"; fi

  if [ -z "$df_list" ]; then
    log_error "Nenhum DISTFILE/DISTFILES encontrado para $port"
    return 4
  fi

  local token outpaths=() failed=0
  for token in $(_tokenize_list "$df_list"); do
    if [ $list_only -eq 1 ]; then
      echo "$token"
      continue
    fi
    outpath=$(fetch_one "$port" "$token" "$force" "$no_verify")
    rc=$?
    if [ $rc -ne 0 ]; then
      log_error "Falha ao baixar $token (rc=$rc)"
      failed=1
      break
    fi
    outpaths+=("$outpath")
  done

  if [ $failed -eq 1 ]; then
    return 5
  fi

  # imprimir caminhos baixados
  for f in "${outpaths[@]}"; do printf '%s\n' "$f"; done

  return 0
}
