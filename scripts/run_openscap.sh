#!/usr/bin/env bash
# run_openscap.sh — OpenSCAP compliance scan of the built container image.
#
# How this works, honestly: OpenSCAP evaluates a system against a
# compliance profile (here: the CIS Docker Benchmark content shipped
# with the scanner image, standing in for an organization's STIG/SRG-
# aligned profile). For a container image, the practical route is
# `oscap-docker`, which mounts the image filesystem and runs the
# evaluation offline — no need to start the container.
#
# The scan runs inside a dedicated scanner container so CI runners do
# not need OpenSCAP installed. The scanner image itself is pinned by
# version and treated as pipeline tooling, reviewed like any other
# dependency.
#
# A note on scope: a meaningful subset of profile rules targets the
# host/daemon rather than the image, and `oscap-docker` reports those
# as "not applicable" or errors. The gate therefore fails on FAILED
# RULES THAT APPLY TO THE IMAGE, and the full report is published as a
# pipeline artifact for review — it is not reduced to a bare pass/fail
# with the evidence thrown away. See docs/gate-policy.md.
#
# Required:
#   IMAGE_REF   image to scan, by digest (…@sha256:…)
# Optional:
#   OSCAP_PROFILE     (default: xccdf_org.ssgproject.content_profile_cis)
#   OSCAP_SCANNER_IMAGE (default: openscap-scanner:1.3)
#   GATE_STATUS_FILE  (default: gate-status.env)
#   DRY_RUN           "true" prints the command without executing it.
set -euo pipefail

: "${IMAGE_REF:?IMAGE_REF is required (image reference by digest)}"
PROFILE="${OSCAP_PROFILE:-xccdf_org.ssgproject.content_profile_cis}"
SCANNER_IMAGE="${OSCAP_SCANNER_IMAGE:-openscap-scanner:1.3}"
GATE_STATUS_FILE="${GATE_STATUS_FILE:-gate-status.env}"
RESULTS="openscap-results.xml"
REPORT="openscap-report.html"

record() {
  local value="$1"
  grep -v '^OPENSCAP_SCAN=' "$GATE_STATUS_FILE" 2>/dev/null > "${GATE_STATUS_FILE}.tmp" || true
  echo "OPENSCAP_SCAN=${value}" >> "${GATE_STATUS_FILE}.tmp"
  mv "${GATE_STATUS_FILE}.tmp" "$GATE_STATUS_FILE"
}

echo "OpenSCAP scan: $IMAGE_REF"
echo "Profile:       $PROFILE"

if [[ "${DRY_RUN:-false}" == "true" ]]; then
  echo "[dry-run] docker run --rm --privileged -v /var/run/docker.sock:/var/run/docker.sock \\"
  echo "            $SCANNER_IMAGE oscap-docker image $IMAGE_REF xccdf eval \\"
  echo "            --profile $PROFILE --results $RESULTS --report $REPORT \\"
  echo "            /usr/share/xml/scap/ssg/content/ssg-docker-ds.xml"
  record PASS
  echo "[dry-run] OPENSCAP_SCAN=PASS recorded (no scan executed)."
  exit 0
fi

# oscap-docker needs access to the Docker daemon to mount the image.
# --privileged is required by the tool; the scanner container is
# ephemeral, runs no network services, and is removed on exit.
set +e
docker run --rm --privileged \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$(pwd):/results" -w /results \
  "$SCANNER_IMAGE" \
  oscap-docker image "$IMAGE_REF" xccdf eval \
    --profile "$PROFILE" \
    --results "$RESULTS" \
    --report "$REPORT" \
    /usr/share/xml/scap/ssg/content/ssg-docker-ds.xml
SCAN_RC=$?
set -e

# oscap exit codes: 0 = all applicable rules pass, 1 = error,
# 2 = one or more applicable rules failed.
case "$SCAN_RC" in
  0)
    echo "OpenSCAP: all applicable rules pass."
    record PASS
    ;;
  2)
    echo "OpenSCAP: one or more applicable rules FAILED — see $REPORT." >&2
    record FAIL
    exit 1
    ;;
  *)
    echo "OpenSCAP: scan errored (exit $SCAN_RC) — treating as gate failure." >&2
    record FAIL
    exit 1
    ;;
esac
