#!/usr/bin/env bash
# modules/update.sh
# Verifica novas versões dos ports com suporte a UPDATE_METHOD e UPDATE_REGEX

PORTSDIR=${PORTSDIR:-/usr/ports}
LOGFILE=${LOGFILE:-/var/log/package/update-report.txt}
USER_AGENT=${USER_AGENT:-"package-update/3.0"}
GIT_TIMEOUT=${GIT_TIMEOUT:-20}

mkdir -p "$(dirname "$LOGFILE")"

# logging
log_info(){ echo "[update][INFO] $*"; }
log_warn(){ echo "[update][WARN] $*"; }
log_error(){ echo "[update][ERROR] $*" >&2; }

# lê variável do Makefile
_makefile_var() {
  local mf="$1" var="$2"
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

# extrai versão do Makefile
_port_version() {
  local mf="$1"
  local v
  for var in VERSION DISTVERSION PORTVERSION; do
    v=$(_makefile_var "$mf" "$var")
    [ -n "$v" ] && { echo "$v"; return; }
  done
  echo "0.0.0"
}

# compara versões (0: igual, 1: nova disponível)
_compare_versions() {
  [ "$1" = "$2" ] && return 0
  if printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1 | grep -qx "$1"; then
    return 1
  fi
  return 0
}

# HTTP/HTTPS/FTP: pega maior versão encontrada
_latest_from_http() {
  local url="$1" regex="$2"
  local html
  if command -v curl >/dev/null; then
    html=$(curl -fsL --user-agent "$USER_AGENT" "$url" | tr -d '\r' | tr '\n' ' ')
  elif command -v wget >/dev/null; then
    html=$(wget -qO- --user-agent="$USER_AGENT" "$url" | tr -d '\r' | tr '\n' ' ')
  else
    return 1
  fi
  regex=${regex:-'[0-9]+\.[0-9]+(\.[0-9]+)?'}
  echo "$html" | grep -Eo "$regex" | sort -V | tail -n1
}

# Git: lista tags
_latest_from_git() {
  local repo="$1" regex="$2"
  local tags
  tags=$(timeout "$GIT_TIMEOUT" git ls-remote --tags "$repo" 2>/dev/null | awk '{print $2}' | sed 's#refs/tags/##')
  regex=${regex:-'^[0-9]+\.[0-9]+(\.[0-9]+)?$'}
  echo "$tags" | grep -E "$regex" | sort -V | tail -n1
}

# SVN: pega última revisão
_latest_from_svn() {
  local repo="$1"
  svn info "$repo" 2>/dev/null | awk '/Revision:/ {print $2}'
}

# decide método
_detect_latest() {
  local mf="$1"
  local method regex
  method=$(_makefile_var "$mf" "UPDATE_METHOD")
  regex=$(_makefile_var "$mf" "UPDATE_REGEX")

  case "$method" in
    git)
      local gitrepo=$(_makefile_var "$mf" "GIT_REPOSITORY")
      [ -n "$gitrepo" ] && _latest_from_git "$gitrepo" "$regex"
      ;;
    svn)
      local svnrepo=$(_makefile_var "$mf" "SVN_REPOSITORY")
      [ -n "$svnrepo" ] && _latest_from_svn "$svnrepo"
      ;;
    http|ftp|https)
      local site=$(_makefile_var "$mf" "MASTER_SITES")
      [ -n "$site" ] && _latest_from_http "$site" "$regex"
      ;;
    *)
      # fallback
      local gitrepo=$(_makefile_var "$mf" "GIT_REPOSITORY")
      local svnrepo=$(_makefile_var "$mf" "SVN_REPOSITORY")
      local site=$(_makefile_var "$mf" "MASTER_SITES")
      local home=$(_makefile_var "$mf" "HOMEPAGE")

      if [ -n "$gitrepo" ]; then
        _latest_from_git "$gitrepo" "$regex"
      elif [ -n "$svnrepo" ]; then
        _latest_from_svn "$svnrepo"
      elif [ -n "$site" ]; then
        _latest_from_http "$site" "$regex"
      elif [ -n "$home" ]; then
        _latest_from_http "$home" "$regex"
      fi
      ;;
  esac
}

# função principal
cmd_update() {
  log_info "Iniciando checagem de updates em $PORTSDIR"
  echo "==== Relatório de Updates $(date) ====" > "$LOGFILE"

  local port mf localver latest
  while IFS= read -r -d '' mf; do
    port=${mf#"$PORTSDIR"/}
    port=${port%/Makefile}

    localver=$(_port_version "$mf")
    latest=$(_detect_latest "$mf")

    if [ -n "$latest" ]; then
      _compare_versions "$localver" "$latest"
      if [ $? -eq 1 ]; then
        log_info "Update encontrado: $port ($localver -> $latest)"
        echo "$port: $localver -> $latest" >> "$LOGFILE"
        if command -v notify-send >/dev/null; then
          notify-send "Update disponível" "$port: $localver -> $latest"
        fi
      fi
    fi
  done < <(find "$PORTSDIR" -mindepth 2 -maxdepth 2 -name Makefile -print0)

  log_info "Relatório gerado em $LOGFILE"
}
