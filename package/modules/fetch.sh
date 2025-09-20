#!/usr/bin/env bash
# modules/fetch.sh
# Baixa fontes do port: tarballs, múltiplos arquivos e múltiplos repositórios git.

PORTSDIR=${PORTSDIR:-/usr/ports}
DISTDIR=${DISTDIR:-/var/cache/package/distfiles}
WORKDIR=${WORKDIR:-/var/cache/package/work}
USER_AGENT=${USER_AGENT:-"package-fetch/3.0"}

mkdir -p "$DISTDIR" "$WORKDIR"

# logging
log_info(){ echo -e "\033[32m[fetch][INFO]\033[0m $*"; }
log_warn(){ echo -e "\033[33m[fetch][WARN]\033[0m $*"; }
log_error(){ echo -e "\033[31m[fetch][ERROR]\033[0m $*" >&2; }

# Lê variável do Makefile
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

# Baixa arquivo (wget ou curl)
_download_file() {
  local url="$1" out="$2"
  if command -v curl >/dev/null; then
    curl -fsL --retry 3 --user-agent "$USER_AGENT" -o "$out" "$url"
  elif command -v wget >/dev/null; then
    wget -q --tries=3 --user-agent="$USER_AGENT" -O "$out" "$url"
  else
    log_error "Nem curl nem wget disponíveis"
    return 1
  fi
}

# Baixa tarballs de MASTER_SITES
_fetch_distfiles() {
  local mf="$1"
  local sites files file url success

  sites=$(_makefile_var "$mf" "MASTER_SITES")
  files=$(_makefile_var "$mf" "DISTFILES")

  for file in $files; do
    success=0
    for site in $sites; do
      url="${site%/}/$file"
      log_info "Baixando $url"
      if _download_file "$url" "$DISTDIR/$file"; then
        log_info "Salvo em $DISTDIR/$file"
        success=1
        break
      else
        log_warn "Falhou em $url"
      fi
    done
    [ $success -eq 0 ] && log_error "Não foi possível baixar $file" && return 1
  done
}

# Clona múltiplos repositórios Git
_fetch_git_repos() {
  local mf="$1"
  local repos repo name branch commit target

  repos=$(_makefile_var "$mf" "GIT_REPOSITORIES")
  [ -z "$repos" ] && return 0

  for repo in $repos; do
    # Deriva nome curto (ex.: gcc-plugins.git -> gcc-plugins)
    name=$(basename "$repo" .git)
    target="$WORKDIR/$name"

    branch=$(_makefile_var "$mf" "GIT_BRANCH_$name")
    commit=$(_makefile_var "$mf" "GIT_COMMIT_$name")

    if [ -d "$target/.git" ]; then
      log_info "Atualizando repositório git $name"
      git -C "$target" fetch --all --tags
    else
      log_info "Clonando $repo em $target"
      git clone --depth 1 ${branch:+-b "$branch"} "$repo" "$target"
    fi

    if [ -n "$commit" ]; then
      log_info "Checkout em commit $commit para $name"
      git -C "$target" checkout "$commit"
    fi
  done
}

# Função principal
cmd_fetch() {
  local port="$1"
  [ -n "$port" ] || { log_error "Uso: package fetch <categoria/port>"; return 2; }

  local mf="$PORTSDIR/$port/Makefile"
  [ -f "$mf" ] || { log_error "Makefile não encontrado em $mf"; return 1; }

  log_info "Iniciando fetch de $port"
  _fetch_distfiles "$mf" || return 1
  _fetch_git_repos "$mf" || return 1
  log_info "Fetch concluído para $port"
}
