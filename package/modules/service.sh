#!/usr/bin/env bash
# modules/service.sh
# Funções para integrar pacotes com systemd (criar unidade a partir de template)

SYSTEMD_DIR=/etc/systemd/system

# Cria um unit file systemd minimal a partir de parâmetros
package_unit_create() {
  local name="$1"         # nome do serviço
  local exec_start="$2"   # comando start (ex: /usr/local/sbin/httpd -D FOOBAR)
  local desc=${3:-"package service $name"}

  local unit_file="$SYSTEMD_DIR/$name.service"
  cat > "$unit_file" <<UNIT
[Unit]
Description=$desc
After=network.target

[Service]
Type=simple
User=root
ExecStart=$exec_start
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
  log "Unit criada: $unit_file"
  systemctl daemon-reload
}

cmd_service() {
  local name=$1; shift || true
  local action=${1:-status}
  case "$action" in
    start|stop|restart|status|enable|disable)
      systemctl "$action" "$name".service
      ;;
    create)
      # usage: package service mysvc create "/usr/local/bin/mysvc --daemon" "Meu Serviço"
      package_unit_create "$name" "$2" "$3"
      ;;
    *) err "Uso: package service <name> <start|stop|restart|create|enable|disable|status>"; return 2 ;;
  esac
}
