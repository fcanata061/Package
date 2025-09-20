#!/usr/bin/env bash
# logs.sh - módulo de logging centralizado para o sistema de build
# Fornece funções de log, rotação e agregação

set -euo pipefail
IFS=$'\n\t'

LOG_DIR=${LOG_DIR:-/var/log/package}
LOG_RETENTION=${LOG_RETENTION:-7}   # dias
BUILD_LOG_DIR="$LOG_DIR/build"

mkdir -p "$LOG_DIR" "$BUILD_LOG_DIR"

# ---------- Funções básicas de log ----------
log_ts(){ date '+%Y-%m-%d %H:%M:%S'; }

log_info(){ echo "[$(log_ts)] [INFO] $*" | tee -a "$LOG_DIR/package.log"; }
log_warn(){ echo "[$(log_ts)] [WARN] $*" | tee -a "$LOG_DIR/package.log" >&2; }
log_error(){ echo "[$(log_ts)] [ERROR] $*" | tee -a "$LOG_DIR/package.log" >&2; }

# ---------- Logs por fase de build ----------
# Usage: log_phase_start PHASE
log_phase_start(){
  local phase="$1"
  echo "[$(log_ts)] === Iniciando fase: $phase ===" | tee -a "$BUILD_LOG_DIR/$phase.log"
}

# Usage: log_phase_end PHASE
log_phase_end(){
  local phase="$1"
  echo "[$(log_ts)] === Fase concluída: $phase ===" | tee -a "$BUILD_LOG_DIR/$phase.log"
}

# ---------- Rotação de logs ----------
rotate_logs(){
  find "$LOG_DIR" -type f -name '*.log' -mtime +"$LOG_RETENTION" -exec rm -f {} +
  find "$BUILD_LOG_DIR" -type f -name '*.log' -mtime +"$LOG_RETENTION" -exec rm -f {} +
}

# ---------- Agregação de logs ----------
# Junta todos os logs de fases em um único arquivo
aggregate_build_logs(){
  local out="$BUILD_LOG_DIR/build-$(date +%Y%m%d%H%M%S).log"
  log_info "Agregando logs de build em $out"
  cat "$BUILD_LOG_DIR"/*.log > "$out" 2>/dev/null || true
  echo "$out"
}

# ---------- Captura de saída de comandos ----------
# Usage: log_command PHASE COMMAND...
log_command(){
  local phase="$1"; shift
  local logfile="$BUILD_LOG_DIR/$phase.log"
  mkdir -p "$BUILD_LOG_DIR"
  echo "[$(log_ts)] >> $*" >> "$logfile"
  "$@" >> "$logfile" 2>&1
}

export -f log_info log_warn log_error log_phase_start log_phase_end rotate_logs aggregate_build_logs log_command
