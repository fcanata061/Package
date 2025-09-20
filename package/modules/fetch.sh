#!/usr/bin/env bash
# modules/fetch.sh
# cmd_fetch <categoria/port>
# - suporta múltiplos DISTFILES e MASTER_SITES
# - suporta GIT_REPOSITORIES (múltiplos), GIT_BRANCH_<name>, GIT_COMMIT_<name>
# - verifica checksums via distinfo se VERIFY_CHECKSUMS=yes
# - respeita /etc/package.conf: DISTDIR, WORKDIR, VERIFY_CHECKSUMS, FETCH_RETRIES, DOWNLOAD_CONTINUE, ALLOW_NETWORK_FETCH, USER_AGENT, GIT_SHALLOW, GIT_DEPTH
# - grava logs simples

set -euo pipefail

[ -f /etc/package.conf ] && source /etc/package.conf

PORTSDIR=${PORTSDIR:-/usr/ports}
DISTDIR=${DISTDIR:-/var/cache/package/distfiles}
WORKDIR=${WORKDIR:-/var/cache/package/work}
USER_AGENT=${USER_AGENT:-"package-fetch/1.0"}
VERIFY_CHECKSUMS=${VERIFY_CHECKSUMS:-yes}
DISTINFO_FILE=${DISTINFO_FILE:-distinfo}
FETCH_RETRIES=${FETCH_RETRIES:-3}
DOWNLOAD_CONTINUE=${DOWNLOAD_CONTINUE:-yes}
ALLOW_NETWORK_FETCH=${ALLOW_NETWORK_FETCH:-yes}
GIT_SHALLOW=${GIT_SHALLOW:-yes}
GIT_DEPTH=${GIT_DEPTH:-1}

mkdir -p "$DISTDIR" "$WORKDIR"

# logging fallbacks
: "${log_info:=:}"; : "${log_warn:=:}"; : "${log_error:=:}"
if ! declare -F log_info >/dev/null; then log_info(){ echo "[fetch][INFO] $*"; }; fi
if ! declare -F log_warn >/dev/null; then log_warn(){ echo "[fetch][WARN] $*"; }; fi
if ! declare -F log_error >/dev/null; then log_error(){ echo "[fetch][ERROR] $*" >&2; }; fi

# read makefile variable with continuation support
_makefile_var(){
  local mf="$1" var="$2"
  [ -f "$mf" ] || return 1
  awk -v v="$var" '
    $0 ~ "^[[:space:]]*"v"[[:space:]]*=" {
      sub("^[[:space:]]*"v"[[:space:]]*=","");
      val=$0;
      while (val ~ /\\$/) { sub(/\\$/,"",val); if (getline nx) val = val nx; else break; }
      gsub(/^[[:space:]]+/,"",val); gsub(/[[:space:]]+$/,"",val);
      print val;
    }' "$mf" | sed 's/#.*//' | xargs || true
}

# parse distinfo for SHA256 for a given filename (simple grep)
_distinfo_sha256(){
  local mf="$1" file="$2"
  local d="$PORTSDIR/${mf%/Makefile}/$DISTINFO_FILE"
  if [ -f "$d" ]; then
    # looks for "SHA256 (filename) = abc..."
    awk -v f="$file" 'tolower($0) ~ "sha256" && tolower($0) ~ f { for(i=1;i<=NF;i++) if($i=="=") { print $(i+1); exit } }' "$d" | tr -d '()' | tr -d '\r' || true
  fi
}

# download helper (curl preferred)
_download_with_retry(){
  local url="$1" out="$2"
  local tries=${FETCH_RETRIES}
  local ok=1
  for i in $(seq 1 $tries); do
    if [ "$ALLOW_NETWORK_FETCH" != "yes" ]; then
      log_warn "Network fetch desabilitado; pulando download $url"
      return 1
    fi
    if command -v curl >/dev/null 2>&1; then
      if [ "$DOWNLOAD_CONTINUE" = "yes" ] && [ -f "$out" ]; then
        log_info "Tentando continuar download (curl -C -): $url"
        curl -C - -fL --retry 3 --user-agent "$USER_AGENT" -o "$out" "$url" && { ok=0; break; } || true
      else
        curl -fL --retry 3 --user-agent "$USER_AGENT" -o "$out" "$url" && { ok=0; break; } || true
      fi
    elif command -v wget >/dev/null 2>&1; then
      if [ "$DOWNLOAD_CONTINUE" = "yes" ] && [ -f "$out" ]; then
        wget -c --user-agent="$USER_AGENT" -O "$out" "$url" && { ok=0; break; } || true
      else
        wget --tries=3 --user-agent="$USER_AGENT" -O "$out" "$url" && { ok=0; break; } || true
      fi
    else
      log_error "Nenhum downloader (curl/wget) disponível"
      return 1
    fi
    log_warn "Tentativa $i falhou para $url; retry..."
    sleep 1
  done
  [ $ok -eq 0 ] && return 0 || return 1
}

# fetch distfiles (multiple)
_fetch_distfiles(){
  local mf="$1"
  local sites files file site url out
  sites=$(_makefile_var "$mf" "MASTER_SITES")
  files=$(_makefile_var "$mf" "DISTFILES")
  if [ -z "$files" ]; then
    log_info "Nenhum DISTFILES definido em $mf"
    return 0
  fi

  for file in $files; do
    out="$DISTDIR/$file"
    if [ -f "$out" ]; then
      log_info "Arquivo já existe em cache: $out"
      # verify checksum if requested
      if [ "$VERIFY_CHECKSUMS" = "yes" ]; then
        local want)
        want=$(_distinfo_sha256 "$mf" "$file")
        if [ -n "$want" ] && command -v sha256sum >/dev/null 2>&1; then
          local got; got=$(sha256sum "$out" | awk '{print $1}')
          if [ "$got" != "$want" ]; then
            log_warn "Checksum mismatch para $file (cache). Removendo e baixando de novo."
            rm -f "$out"
          else
            log_info "Checksum OK para $file"
            continue
          fi
        fi
      else
        continue
      fi
    fi

    local success=0
    for site in $sites; do
      site="${site%/}"
      url="${site%/}/$file"
      log_info "Tentando baixar $url"
      if _download_with_retry "$url" "$out"; then
        log_info "Download OK: $out"
        success=1
        break
      else
        log_warn "Falha ao baixar $url"
      fi
    done

    if [ "$success" -eq 0 ]; then
      log_error "Não foi possível obter $file (tentou ${sites:-none})"
      return 1
    fi

    # verify checksum if possible
    if [ "$VERIFY_CHECKSUMS" = "yes" ]; then
      local want; want=$(_distinfo_sha256 "$mf" "$file")
      if [ -n "$want" ] && command -v sha256sum >/dev/null 2>&1; then
        local got; got=$(sha256sum "$out" | awk '{print $1}')
        if [ "$got" != "$want" ]; then
          log_error "Checksum inválido para $file (esperado $want, obtido $got)"
          rm -f "$out"
          return 1
        fi
      fi
    fi
  done

  return 0
}

# fetch git repos (multiple)
_fetch_git_repos(){
  local mf="$1"
  local repos repo name target branch commit depth
  repos=$(_makefile_var "$mf" "GIT_REPOSITORIES")
  if [ -z "$repos" ]; then return 0; fi

  for repo in $repos; do
    name=$(basename "$repo" .git)
    target="$WORKDIR/$name"
    branch=$(_makefile_var "$mf" "GIT_BRANCH_$name")
    commit=$(_makefile_var "$mf" "GIT_COMMIT_$name")
    depth_opt=""
    if [ "$GIT_SHALLOW" = "yes" ] && [ -n "$GIT_DEPTH" ]; then depth_opt="--depth $GIT_DEPTH"; fi

    if [ -d "$target/.git" ]; then
      log_info "Atualizando repositório git $repo -> $target"
      git -C "$target" fetch --all --tags || log_warn "git fetch falhou para $target"
      if [ -n "$branch" ]; then git -C "$target" checkout "$branch" || true; fi
      if [ -n "$commit" ]; then git -C "$target" checkout "$commit" || true; fi
    else
      log_info "Clonando $repo -> $target"
      if command -v git >/dev/null 2>&1; then
        git clone $depth_opt ${branch:+-b "$branch"} "$repo" "$target" || { log_error "git clone falhou para $repo"; return 1; }
        if [ -n "$commit" ]; then git -C "$target" checkout "$commit" || true; fi
      else
        log_error "git não disponível para clonar $repo"
        return 1
      fi
    fi
  done
}

# Main entry point
cmd_fetch(){
  local port="$1"
  [ -n "$port" ] || { log_error "Uso: package fetch <categoria/port>"; return 2; }
  local mf="$PORTSDIR/$port/Makefile"
  if [ ! -f "$mf" ]; then log_error "Makefile não encontrado: $mf"; return 1; fi

  log_info "Iniciando fetch para $port"
  if ! _fetch_distfiles "$mf"; then log_error "fetch distfiles falhou"; return 1; fi
  if ! _fetch_git_repos "$mf"; then log_error "fetch git repos falhou"; return 1; fi
  log_info "Fetch concluído para $port"
  return 0
}

export -f cmd_fetch
