#!/usr/bin/env bash
# modules/remove.sh
# Remove um port instalado
#
# Fluxo:
# 1. Verificar se o port está instalado
# 2. Executar hooks pre_remove
# 3. Remover arquivos registrados
# 4. Executar hooks post_remove
# 5. Registrar no log/histórico

INSTALLED_DB=${INSTALLED_DB:-/var/lib/package/installed}

mkdir -p "$(dirname "$INSTALLED_DB")"
touch "$INSTALLED_DB"

is_installed() {
  local port_path="$1"
  grep -q "^$port_path " "$INSTALLED_DB"
}

unregister_port() {
  local port_path="$1"
  grep -v "^$port_path " "$INSTALLED_DB" > "$INSTALLED_DB.tmp"
  mv "$INSTALLED_DB.tmp" "$INSTALLED_DB"
}

cmd_remove() {
  local port_path="$1"
  [ -n "$port_path" ] || { err "Uso: package remove <categoria/port>"; return 2; }

  if ! is_installed "$port_path"; then
    err "Port $port_path não está instalado"
    return 1
  fi

  log_info "Iniciando remoção de $port_path"
  log_port "$port_path" "Remoção iniciada"

  # Hooks pre_remove
  run_pre_remove "$port_path" || {
    log_error "Hook pre_remove falhou para $port_path"
    return 1
  }

  # Recuperar lista de arquivos instalados
  local files_list="/var/lib/package/files/$(echo "$port_path" | tr '/' '_').list"
  if [ -f "$files_list" ]; then
    while read -r f; do
      if [ -e "$f" ]; then
        rm -rf "$f"
        log_port "$port_path" "Removido: $f"
      fi
    done < "$files_list"
    rm -f "$files_list"
  else
    log_warn "Nenhuma lista de arquivos encontrada para $port_path"
  fi

  # Hooks post_remove
  run_post_remove "$port_path" || {
    log_error "Hook post_remove falhou para $port_path"
    return 1
  }

  # Atualizar DB
  unregister_port "$port_path"

  log_info "Port $port_path removido com sucesso"
  log_port "$port_path" "Remoção concluída"
  register_action "remove" "$port_path" "success"
}
