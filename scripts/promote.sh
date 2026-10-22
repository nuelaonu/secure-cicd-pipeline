#!/usr/bin/env bash
# promote.sh — promote ONE immutable image digest across environments.
#
# Promotion contract (see README "Promotion contract"):
#   1. The image is built exactly once and identified by digest
#      (registry/repo@sha256:...). Promotion never rebuilds.
#   2. Promotion re-tags the SAME digest with the target environment
#      tag (<env>-<short-sha>) using a registry-side copy
#      (`docker buildx imagetools create`), so the digest in prod is
#      bit-for-bit the digest that passed every gate in dev.
#   3. Promotion REFUSES to run unless the gate-status file produced
#      by the scan/compliance stages says every gate passed.
#   4. stage and prod require a human approval upstream (GitLab
#      `when: manual` / GitHub Environment protection rules). This
#      script enforces the technical preconditions; it does not
#      replace the human gate — see PROMOTE_APPROVED below.
#
# Usage:
#   IMAGE_REF=registry.example.internal/team/sample-service@sha256:<digest> \
#   IMAGE_TAG=dev-abc1234 \
#   TARGET_ENV=stage \
#   GATE_STATUS_FILE=gate-status.env \
#   ./scripts/promote.sh
#
# Environment inputs:
#   IMAGE_REF          (required) source image, by digest
#   IMAGE_TAG          (required) immutable tag the build produced (e.g. dev-abc1234)
#   TARGET_ENV         (required) dev | stage | prod
#   GATE_STATUS_FILE   (default: gate-status.env) KEY=VALUE file written
#                      by earlier stages: SONAR_GATE, ANCHORE_SCAN,
#                      OPENSCAP_SCAN each set to PASS or FAIL
#   PROMOTE_APPROVED   must be "true" for stage/prod. The pipelines set
#                      this only inside the manually-approved job, which
#                      is what ties the human click to this script.
#   DRY_RUN            "true" prints the commands without executing them.
set -euo pipefail

: "${IMAGE_REF:?IMAGE_REF is required (image reference by digest)}"
: "${IMAGE_TAG:?IMAGE_TAG is required (e.g. dev-abc1234)}"
: "${TARGET_ENV:?TARGET_ENV is required (dev, stage, or prod)}"
GATE_STATUS_FILE="${GATE_STATUS_FILE:-gate-status.env}"
DRY_RUN="${DRY_RUN:-false}"

case "$TARGET_ENV" in
  dev|stage|prod) ;;
  *) echo "ERROR: TARGET_ENV must be dev, stage, or prod (got: $TARGET_ENV)" >&2; exit 2 ;;
esac

# The source must be pinned by digest. A mutable tag as the source
# would let the promoted bits differ from the scanned bits.
case "$IMAGE_REF" in
  *@sha256:*) ;;
  *) echo "ERROR: IMAGE_REF must be pinned by digest (…@sha256:…), got: $IMAGE_REF" >&2; exit 2 ;;
esac

# --- Gate check -------------------------------------------------------
# Refuse promotion when any gate failed or never reported. Missing
# evidence is treated as a failure, not as a pass.
if [[ ! -f "$GATE_STATUS_FILE" ]]; then
  echo "ERROR: gate status file not found: $GATE_STATUS_FILE — refusing to promote without gate evidence." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$GATE_STATUS_FILE"
for gate in SONAR_GATE ANCHORE_SCAN OPENSCAP_SCAN; do
  value="${!gate:-MISSING}"
  if [[ "$value" != "PASS" ]]; then
    echo "ERROR: gate $gate is '$value' — promotion to $TARGET_ENV refused." >&2
    exit 1
  fi
  echo "gate $gate: PASS"
done

# --- Human approval check (stage / prod) ------------------------------
if [[ "$TARGET_ENV" != "dev" && "${PROMOTE_APPROVED:-false}" != "true" ]]; then
  echo "ERROR: promotion to $TARGET_ENV requires manual approval." >&2
  echo "       Run this from the approved pipeline job (which sets PROMOTE_APPROVED=true)." >&2
  exit 1
fi

# --- Re-tag the same digest -------------------------------------------
# Strip the digest to get the repository, then registry-side copy the
# manifest to the environment tag. `imagetools create` does not pull
# or rebuild layers — the target tag points at the identical digest.
REPO="${IMAGE_REF%@*}"
SHORT_SHA="${IMAGE_TAG##*-}"
TARGET_REF="${REPO}:${TARGET_ENV}-${SHORT_SHA}"

echo "Promoting $IMAGE_REF"
echo "       -> $TARGET_REF (same digest, new tag)"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "[dry-run] docker buildx imagetools create --tag $TARGET_REF $IMAGE_REF"
  echo "[dry-run] docker buildx imagetools inspect $TARGET_REF"
else
  docker buildx imagetools create --tag "$TARGET_REF" "$IMAGE_REF"
  docker buildx imagetools inspect "$TARGET_REF"
fi

echo "Promotion complete: $TARGET_ENV now points at the digest from $IMAGE_TAG."
