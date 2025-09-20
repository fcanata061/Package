#!/usr/bin/env bash
# modules/logs.sh
# Gerenciamento de logs e registros do gerenciador "package"
#
# Variáveis em /etc/package.conf:
# LOG_DIR=/var/log/package
# LOG_LEVEL=INFO

LOG_DIR=${LOG_DIR:-/var/log/package}
LOG_LEVEL=${LOG_LEVEL:-INFO}

mkdir -p "$LOG_DIR"

# Função de log interno (console + arquivo)
log_message() {
  local level="$1"; shift
  local msg="$*"
  local timestamp
  timestamp=$(date +"%Y-%m-%d %H:%M:%S")

  # Console
  echo "[$timestamp][$level] $msg"

  # Arquivo principal
  echo "[$timestamp][$level] $msg" >> "$LOG_DIR/package.log"
}

# Helpers de nível
log_info()  { log_message "INFO" "$*"; }
log_warn()  { log_message "WARN" "$*"; }
log_error() { log_message "ERROR" "$*"; }
log_debug() { [ "$LOG_LEVEL" = "DEBUG" ] && log_message "DEBUG" "$*"; }

# Logs específicos por port
log_port() {
  local port_path="$1"; shift
  local msg="$*"
  local port_log="$LOG_DIR/$(echo "$port_path" | tr '/' '_').log"
  local timestamp
  timestamp=$(date +"%Y-%m-%d %H:%M:%S")

  echo "[$timestamp] $msg" >> "$port_log"
}

# Registro de operações (ex: histórico)
register_action() {
  local action="$1"; shift
  local port_path="$1"; shift
  local status="$1"; shift || true

  local timestamp
  timestamp=$(date +"%Y-%m-%d %H:%M:%S")

  echo "$timestamp | action=$action | port=$port_path | status=$status" \
    >> "$LOG_DIR/history.log"
}

# CLI
cmd_logs() {
  local action="$1"; shift || true
  case "$action" in
    tail)
      tail -f "$LOG_DIR/package.log"
      ;;
    show)
      local port_path="$1"
      local port_log="$LOG_DIR/$(echo "$port_path" | tr '/' '_').log"
      [ -f "$port_log" ] && cat "$port_log" || err "Sem log para $port_path"
      ;;
    history)
      cat "$LOG_DIR/history.log"
      ;;
    clear)
      rm -f "$LOG_DIR"/*.log
      log_info "Logs limpos"
      ;;
    *)
      echo "Uso: package logs <tail|show <port>|history|clear>"
      return 2
      ;;
  esac
}
