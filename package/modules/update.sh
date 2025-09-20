#!/usr/bin/env bash
# modules/update.sh
# Verifica novas versões dos ports (HTTP, git, svn) e gera relatório JSON + notify-send.
# Exports: cmd_update

set -euo pipefail

# Load config if available
[ -f /etc/package.conf ] && source /etc/package.conf

# Defaults (só se não definidos no package.conf)
PORTSDIR=${PORTSDIR:-/usr/ports}
UPDATE_REPORT=${UPDATE_REPORT:-${LOG_DIR:-/var/log/package}/update-report.json}
USER_AGENT=${USER_AGENT:-"package-update/3.0"}
GIT_TIMEOUT=${GIT_TIMEOUT:-20}
ALLOW_NETWORK_FETCH=${ALLOW_NETWORK_FETCH:-yes}
NOTIFY_ON_UPDATE=${NOTIFY_ON_UPDATE:-yes}
UPDATE_REGEX_DEFAULT=${UPDATE_REGEX_DEFAULT:-'[0-9]+\.[0-9]+(\.[0-9]+)?'}
PARALLEL_JOBS=${PARALLEL_JOBS:-1}

mkdir -p "$(dirname "$UPDATE_REPORT")"

# Logging fallbacks
: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_error:=:}"
if ! declare -F log_info >/dev/null; then log_info(){ echo "[update][INFO] $*"; }; fi
if ! declare -F log_warn >/dev/null; then log_warn(){ echo "[update][WARN] $*"; }; fi
if ! declare -F log_error >/dev/null; then log_error(){ echo "[update][ERROR] $*" >&2; }; fi

# helpers
_makefile_var() {
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

_port_version_from_mf() {
  local mf="$1" v
  for var in VERSION DISTVERSION PORTVERSION; do
    v=$(_makefile_var "$mf" "$var")
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  done
  printf '%s' "0.0.0"
}

# Detect and fetch latest via HTTP (uses regex), git (tags), svn (revision)
_latest_from_http() {
  local url="$1" regex="${2:-$UPDATE_REGEX_DEFAULT}"
  if [ "$ALLOW_NETWORK_FETCH" != "yes" ]; then
    log_warn "Network fetch disabled by config; skipping HTTP check for $url"
    return 1
  fi
  local html
  if command -v curl >/dev/null 2>&1; then
    html=$(curl -fsL --user-agent "$USER_AGENT" "$url" 2>/dev/null || true)
  elif command -v wget >/dev/null 2>&1; then
    html=$(wget -qO- --user-agent="$USER_AGENT" "$url" 2>/dev/null || true)
  else
    log_error "Nenhum downloader disponível (curl/wget) para checar $url"
    return 1
  fi
  if [ -z "$html" ]; then return 1; fi
  # extract candidates
  printf '%s' "$html" | grep -Eo "$regex" | sort -V | tail -n1 || return 1
}

_latest_from_git() {
  local repo="$1" regex="${2:-$UPDATE_REGEX_DEFAULT}"
  if [ "$ALLOW_NETWORK_FETCH" != "yes" ]; then
    log_warn "Network fetch disabled by config; skipping git check for $repo"
    return 1
  fi
  if ! command -v git >/dev/null 2>&1; then
    log_error "git não disponível para checar $repo"
    return 1
  fi
  # list tags (ls-remote may include annotated tags)
  local tags
  tags=$(timeout "${GIT_TIMEOUT}" git ls-remote --tags "$repo" 2>/dev/null \
    | awk '{print $2}' | sed 's#refs/tags/##' || true)
  if [ -z "$tags" ]; then return 1; fi
  printf '%s\n' "$tags" | grep -E "$regex" | sed 's/^v//' | sort -V | tail -n1 || return 1
}

_latest_from_svn() {
  local repo="$1"
  if [ "$ALLOW_NETWORK_FETCH" != "yes" ]; then
    log_warn "Network fetch disabled by config; skipping svn check for $repo"
    return 1
  fi
  if ! command -v svn >/dev/null 2>&1; then
    log_error "svn não disponível para checar $repo"
    return 1
  fi
  svn info "$repo" 2>/dev/null | awk '/Revision:/ {print $2}' | tail -n1 || return 1
}

# decide melhor método por variables in Makefile (UPDATE_METHOD, GIT_REPOSITORY, SVN_REPOSITORY, MASTER_SITES, HOMEPAGE)
_detect_latest_for_port() {
  local mf="$1"
  local method regex gitrepo svnrepo site homepage
  method=$(_makefile_var "$mf" "UPDATE_METHOD")
  regex=$(_makefile_var "$mf" "UPDATE_REGEX")
  gitrepo=$(_makefile_var "$mf" "GIT_REPOSITORY")
  svnrepo=$(_makefile_var "$mf" "SVN_REPOSITORY")
  site=$(_makefile_var "$mf" "MASTER_SITES")
  homepage=$(_makefile_var "$mf" "HOMEPAGE")

  case "$method" in
    git)
      [ -n "$gitrepo" ] && _latest_from_git "$gitrepo" "$regex" && return 0
      ;;
    svn)
      [ -n "$svnrepo" ] && _latest_from_svn "$svnrepo" && return 0
      ;;
    http|https|ftp)
      [ -n "$site" ] && _latest_from_http "$site" "$regex" && return 0
      [ -n "$homepage" ] && _latest_from_http "$homepage" "$regex" && return 0
      ;;
    auto|"" )
      # try git, svn, master sites, homepage in that order
      if [ -n "$gitrepo" ]; then _latest_from_git "$gitrepo" "$regex" && return 0; fi
      if [ -n "$svnrepo" ]; then _latest_from_svn "$svnrepo" && return 0; fi
      if [ -n "$site" ]; then _latest_from_http "$site" "$regex" && return 0; fi
      if [ -n "$homepage" ]; then _latest_from_http "$homepage" "$regex" && return 0; fi
      ;;
    *)
      log_warn "UPDATE_METHOD desconhecido '$method' em $mf; tentando auto"
      _detect_latest_for_port "$mf" # recursion but method will be empty -> auto path
      return $?
      ;;
  esac
  return 1
}

# version compare helpers
_vnorm(){ printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' ;}
version_gt(){
  local a=$(_vnorm "$1") b=$(_vnorm "$2")
  [ -z "$a" ] && return 1
  [ -z "$b" ] && return 0
  [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)" = "$a" ] && [ "$a" != "$b" ]
}

# create JSON safe string
_json_escape(){ printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# main command
cmd_update() {
  local out_array=()
  log_info "Iniciando verificação de updates em $PORTSDIR"
  # iterate Makefile under ports (depth 2)
  local mf port rel localver latest method regex
  while IFS= read -r -d '' mf; do
    rel=${mf#"$PORTSDIR"/}
    rel=${rel%/Makefile}
    localver=$(_port_version_from_mf "$mf")
    # detect latest
    latest=$(_detect_latest_for_port "$mf" 2>/dev/null || true) || latest=""
    if [ -n "$latest" ]; then
      if version_gt "$latest" "$localver"; then
        log_info "Update disponível: $rel ($localver -> $latest)"
        out_array+=("{\"port\":\"$(_json_escape "$rel")\",\"installed\":\"$(_json_escape "$localver")\",\"available\":\"$(_json_escape "$latest")\",\"homepage\":\"$(_json_escape "$(_makefile_var "$mf" "HOMEPAGE") )\"}")
        # notification
        if [ "${NOTIFY_ON_UPDATE:-yes}" = "yes" ] && command -v notify-send >/dev/null 2>&1; then
          notify-send "Update disponível: $rel" "$localver → $latest"
        fi
      fi
    fi
  done < <(find "$PORTSDIR" -mindepth 2 -maxdepth 2 -name Makefile -print0)

  # write JSON report (array)
  {
    printf '%s\n' "["
    local first=1
    for item in "${out_array[@]}"; do
      if [ $first -eq 1 ]; then printf '  %s\n' "$item"; first=0; else printf '  ,%s\n' "$item"; fi
    done
    printf '%s\n' "]"
  } > "$UPDATE_REPORT.tmp"
  mv -f "$UPDATE_REPORT.tmp" "$UPDATE_REPORT"
  log_info "Relatório de updates escrito em $UPDATE_REPORT"
  return 0
}

# expose
export -f cmd_update
