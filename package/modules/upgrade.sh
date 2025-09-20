#!/usr/bin/env bash
# modules/upgrade.sh
#
# Atualiza automaticamente os pacotes que possuem novas versões disponíveis.
#
# Integra com update.sh, build.sh, fetch.sh, install.sh e register.sh.
#
# Salva relatórios em /var/lib/package/upgrades.
#
# Variáveis:
#   PORTSDIR=/usr/ports
#   UPDATESDIR=/var/lib/package/updates
#   UPGRADESDIR=/var/lib/package/upgrades

set -euo pipefail

[ -f /etc/package.conf ] && source /etc/package.conf

PORTSDIR=${PORTSDIR:-/usr/ports}
UPDATESDIR=${UPDATESDIR:-/var/lib/package/updates}
UPGRADESDIR=${UPGRADESDIR:-/var/lib/package/upgrades}
mkdir -p "$UPDATESDIR" "$UPGRADESDIR"

# --- Logging helpers ---
: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_error:=:}"

if ! declare -F log_info >/dev/null; then
  log_info(){ echo "[upgrade][INFO] $*"; }
fi
if ! declare -F log_warn >/dev/null; then
  log_warn(){ echo "[upgrade][WARN] $*"; }
fi
if ! declare -F log_error >/dev/null; then
  log_error(){ echo "[upgrade][ERROR] $*" >&2; }
fi

_notify() {
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "Package Upgrade" "$*"
  else
    log_info "NOTIFY: $*"
  fi
}

# --- Dependências internas ---
MODULESDIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
source "$MODULESDIR/update.sh"
source "$MODULESDIR/fetch.sh"
source "$MODULESDIR/build.sh"
source "$MODULESDIR/patch.sh"
source "$MODULESDIR/install.sh"
source "$MODULESDIR/register.sh"

# --- Função principal ---

upgrade_all() {
  log_info "Rodando verificação de updates..."
  update_check_all

  for json in "$UPDATESDIR"/*.json; do
    [ -f "$json" ] || continue

    local name current latest src
    name=$(jq -r .name "$json")
    current=$(jq -r .current "$json")
    latest=$(jq -r .latest "$json")
    src=$(jq -r .src "$json")

    log_info "[$name] upgrade $current → $latest"

    local port="$PORTSDIR/$name"
    [ -d "$port" ] || {
      log_warn "Port $name não encontrado em $PORTSDIR"
      continue
    }

    # Execução da pipeline
    {
      log_info "[$name] Baixando fontes..."
      fetch_sources "$port"

      log_info "[$name] Aplicando patches..."
      apply_patches "$port"

      log_info "[$name] Construindo..."
      build_port "$port"

      log_info "[$name] Instalando..."
      install_port "$port"

      log_info "[$name] Registrando..."
      register_port "$port" "$latest"

      log_info "[$name] Upgrade concluído com sucesso."
      _notify "$name atualizado para $latest"
      echo "{\"name\":\"$name\",\"from\":\"$current\",\"to\":\"$latest\",\"status\":\"ok\"}" \
        > "$UPGRADESDIR/$name.json"
    } || {
      log_error "[$name] Falha no upgrade"
      _notify "$name falhou ao atualizar"
      echo "{\"name\":\"$name\",\"from\":\"$current\",\"to\":\"$latest\",\"status\":\"failed\"}" \
        > "$UPGRADESDIR/$name.json"
    }
  done
}

# --- Export ---
export -f upgrade_all

# Execução direta
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  upgrade_all
fi
