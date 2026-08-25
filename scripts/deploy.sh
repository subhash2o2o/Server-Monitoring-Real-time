#!/usr/bin/env bash
set -euo pipefail

# Long-running deploy simulation that produces structured log lines.
# Producer constraint: ONLY this shell script writes events.
# It writes to a plain log file (default: ../logs/deploy.log).

LOG_FILE_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/logs/deploy.log"
LOG_FILE="${LOG_FILE:-$LOG_FILE_DEFAULT}"

mkdir -p "$(dirname "$LOG_FILE")"

iso_ts() {
  # UTC ISO-8601 with milliseconds
  # Example: 2026-01-20T12:34:56.789Z
  date -u +"%Y-%m-%dT%H:%M:%S.%3NZ"
}

log() {
  local level="$1"; shift
  local msg="$*"
  printf '%s | %-5s | %s\n' "$(iso_ts)" "$level" "$msg" >> "$LOG_FILE"
}

step() {
  local name="$1"; shift
  log INFO "START: ${name}"
  "$@"
  log INFO "DONE : ${name}"
}

sleep_s() {
  local seconds="$1"
  sleep "$seconds"
}

main() {
  log INFO "deploy.sh starting (pid=$$)"
  log INFO "writing logs to: $LOG_FILE"

  step "Pre-flight checks" sleep_s 2
  log INFO "Checking connectivity to registry"
  sleep 1
  log WARN "Registry latency elevated; continuing"

  step "Pull artifacts" sleep_s 3
  log INFO "Artifacts pulled successfully"

  step "Apply database migrations" sleep_s 4
  log INFO "Migration 001_add_users OK"
  log INFO "Migration 002_add_indexes OK"

  step "Deploy service" sleep_s 5
  log INFO "Rolling update started"
  sleep 2
  log INFO "Pod 1/3 ready"
  sleep 2
  log INFO "Pod 2/3 ready"
  sleep 2
  log INFO "Pod 3/3 ready"

  # Simulate a recoverable error once.
  log ERROR "Transient error: upstream 503 during healthcheck; retrying"
  sleep 2
  log INFO "Healthcheck retry OK"

  step "Post-deploy verification" sleep_s 3
  log INFO "Smoke tests passed"

  log INFO "deploy.sh completed successfully"
}

main "$@"
