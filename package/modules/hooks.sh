#!/usr/bin/env bash
# modules/hooks.sh
# Gerencia hooks para cada fase do ciclo de vida do port
#
# Hooks suportados:
# - pre_configure
# - post_configure
# - pre_install
# - post_install
# - pre_remove
# - post_remove
#
# Cada hook deve ser um script executável chamado <hook>.sh
# localizado dentro do diretório do port (ex: /usr/ports/net/httpd/hooks/)

run_hook() {
  local port_path="$1"
  local hook="$2"
  local hook_dir="$PORTSDIR/$port_path/hooks"
  local hook_script="$hook_dir/${hook}.sh"

  if [ -x "$hook_script" ]; then
    log "Executando hook $hook para $port_path"
    "$hook_script" "$port_path" || {
      err "Hook $hook falhou para $port_path"
      return 1
    }
  fi
}

# Helpers que podem ser chamados nos módulos build/install/remove
run_pre_configure()  { run_hook "$1" "pre_configure"; }
run_post_configure() { run_hook "$1" "post_configure"; }

run_pre_install()    { run_hook "$1" "pre_install"; }
run_post_install()   { run_hook "$1" "post_install"; }

run_pre_remove()     { run_hook "$1" "pre_remove"; }
run_post_remove()    { run_hook "$1" "post_remove"; }

# Comando CLI para executar hook manualmente
cmd_hook() {
  local port_path="$1"
  local hook="$2"
  [ -n "$port_path" ] || { err "hook requer port (ex: net/httpd)"; return 2; }
  [ -n "$hook" ] || { err "hook requer o nome do hook"; return 2; }
  run_hook "$port_path" "$hook"
}
