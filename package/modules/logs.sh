#!/usr/bin/env bash
# modules/logs.sh
# --- Sistema central de logging ---

LOG_DIR=${LOG_DIR:-/var/log/package}
mkdir -p "$LOG_DIR"

log_info()  { echo "[INFO]  $*" | tee -a "$LOG_DIR/package.log" >&2; }
log_warn()  { echo "[WARN]  $*" | tee -a "$LOG_DIR/package.log" >&2; }
log_error() { echo "[ERROR] $*" | tee -a "$LOG_DIR/package.log" >&2; }
