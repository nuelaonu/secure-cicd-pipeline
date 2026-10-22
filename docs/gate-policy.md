# Gate policy — what fails this pipeline, and why

Every gate in this pipeline exists to answer a specific question, and
each one **fails closed**: a gate that errors, times out, or produces
no evidence is treated as a failure, never as a pass. The promotion
script (`scripts/promote.sh`) re-checks the recorded gate results
before any re-tag, so a gate cannot be skipped by running a later
stage directly.

| Gate | Stage | Fails when | Why this bar |
| --- | --- | --- | --- |
| Unit tests | `test` | Any test fails, or coverage of `app/` drops below 80% | Broken logic must be cheapest to catch here, before any scanning spend. |
| SonarQube quality gate | `quality` | Gate status is not `OK`: new bugs/vulnerabilities, security hotspots unreviewed, coverage on new code below threshold, duplication above threshold | The gate evaluates **new code** conditions, so the bar ratchets: legacy findings are tracked, but a change cannot make things worse. |
| Anchore image scan (Grype) | `scan` | Any **fixable** vulnerability at severity **High or Critical** in the image | "Fixable" is the operative word: a CVE with no available fix is reported and tracked, not used to block delivery forever; a CVE with a fix available has no excuse to ship. Threshold is set by `ANCHORE_FAIL_SEVERITY`. |
| OpenSCAP compliance scan | `compliance` | Any rule **applicable to the image** fails under the selected profile | Baseline hardening (file permissions, disabled extras, package hygiene) is verified mechanically instead of by checklist review. Host/daemon rules report as not-applicable and are covered by host configuration management, not this gate. |
| Manual approval | `promote-stage`, `promote-prod` | No human approves | Deliberately not automatable. Accountability for what runs in stage/prod belongs to a person; the pipeline's job is to guarantee that whatever they approve is byte-identical to what passed the gates. |

## Severity and exception handling

- **Critical, fixable, internet-facing**: no exceptions. Fix first.
- **High, fixable**: blocks promotion by default. A time-boxed
  exception (named owner, expiry date, tracked in the report artifact)
  may be granted by a human reviewer — the pipeline records the gate
  result as measured; exceptions are a documented human decision
  layered on top, never a quiet threshold edit.
- **Scanner or gate infrastructure down**: the pipeline fails. A red
  pipeline because the scanner is down is annoying; a green pipeline
  that silently stopped scanning is a supply-chain incident.

## Artifacts every run keeps

- SonarQube analysis link and gate status
- Grype report (JSON) and SBOM (SPDX JSON) for the exact image digest
- OpenSCAP XCCDF results (XML) and human-readable report (HTML)
- `gate-status.env` — the three gate verdicts the promotion script
  verifies before re-tagging
