#!/usr/bin/env bash
# check_sonar_gate.sh — wait for the SonarQube quality gate and record
# the result in the gate-status file consumed by scripts/promote.sh.
#
# The scanner step submits the analysis; SonarQube computes the gate
# asynchronously, so the pipeline must poll the compute-engine task and
# then read the gate status. Exits non-zero when the gate is not OK,
# which fails the pipeline job — code that fails the gate never
# reaches the image build stage.
#
# Required CI variables (masked, never committed):
#   SONAR_HOST_URL   e.g. https://sonar.example.internal
#   SONAR_TOKEN      analysis token
# Optional:
#   SONAR_PROJECT_KEY  (default: sample-service)
#   GATE_STATUS_FILE   (default: gate-status.env)
#   SONAR_WAIT_SECONDS (default: 300)
set -euo pipefail

: "${SONAR_HOST_URL:?SONAR_HOST_URL is required}"
: "${SONAR_TOKEN:?SONAR_TOKEN is required}"
PROJECT_KEY="${SONAR_PROJECT_KEY:-sample-service}"
GATE_STATUS_FILE="${GATE_STATUS_FILE:-gate-status.env}"
DEADLINE=$(( $(date +%s) + ${SONAR_WAIT_SECONDS:-300} ))

record() {
  # Append/replace SONAR_GATE=<value> in the gate-status file.
  local value="$1"
  grep -v '^SONAR_GATE=' "$GATE_STATUS_FILE" 2>/dev/null > "${GATE_STATUS_FILE}.tmp" || true
  echo "SONAR_GATE=${value}" >> "${GATE_STATUS_FILE}.tmp"
  mv "${GATE_STATUS_FILE}.tmp" "$GATE_STATUS_FILE"
}

while :; do
  STATUS="$(curl -fsS -u "${SONAR_TOKEN}:" \
    "${SONAR_HOST_URL}/api/qualitygates/project_status?projectKey=${PROJECT_KEY}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["projectStatus"]["status"])')"

  case "$STATUS" in
    OK)
      echo "SonarQube quality gate: OK"
      record PASS
      exit 0
      ;;
    ERROR|WARN)
      echo "SonarQube quality gate: $STATUS — failing the pipeline." >&2
      record FAIL
      exit 1
      ;;
    NONE)
      # Analysis still processing on the server side; keep waiting.
      if [[ $(date +%s) -ge $DEADLINE ]]; then
        echo "Timed out waiting for the SonarQube quality gate." >&2
        record FAIL
        exit 1
      fi
      sleep 10
      ;;
    *)
      echo "Unexpected quality gate status: $STATUS" >&2
      record FAIL
      exit 1
      ;;
  esac
done
