#!/usr/bin/env bash
# modules/upgrade.sh
# Atualiza um port instalado
#
# Fluxo:
# 1. Verificar se está instalado
# 2. Executar hook pre_upgrade
# 3. Resolver dependências
# 4. Executar fluxo remove + install
# 5. Executar hook post_upgrade
# 6. Registrar logs

INSTALLED_DB=${INSTALLED_DB:-/var/lib/package/installed}

is_installed() {
  local port_path="$1"
  grep -q "^$port_path " "$INSTALLED_DB"
}

cmd_upgrade() {
  local port_path="$1"
  [ -n "$port_path" ] || { err "Uso: package upgrade <categoria/port>"; return 2; }

  if ! is_installed "$port_path"; then
    err "Port $port_path não está instalado. Use 'package install $port_path'"
    return 1
  fi

  log_info "Iniciando upgrade de $port_path"
  log_port "$port_path" "Upgrade iniciado"

  # Hook pre_upgrade
  run_hook "$port_path" "pre_upgrade" || {
    log_error "Hook pre_upgrade falhou para $port_path"
    return 1
  }

  # Resolver dependências
  cmd_deps "$port_path" || {
    log_error "Falha ao resolver dependências para $port_path"
    return 1
  }

  # Remover versão antiga
  cmd_remove "$port_path" || {
    log_error "Falha ao remover versão antiga de $port_path"
    return 1
  }

  # Instalar versão nova
  cmd_install "$port_path" || {
    log_error "Falha ao instalar nova versão de $port_path"
    return 1
  }

  # Hook post_upgrade
  run_hook "$port_path" "post_upgrade" || {
    log_error "Hook post_upgrade falhou para $port_path"
    return 1
  }

  log_info "Port $port_path atualizado com sucesso"
  log_port "$port_path" "Upgrade concluído"
  register_action "upgrade" "$port_path" "success"
}
