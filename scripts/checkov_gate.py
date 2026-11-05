#!/usr/bin/env python3
"""Fail the build when Checkov reports a finding from the high-risk rule set.

Checkov's severity metadata is only populated when it is connected to the
Prisma Cloud platform, so relying on `--hard-fail-on HIGH` silently degrades to
"nothing fails" in an offline CI runner. This gate keeps an explicit, reviewable
list of the checks that must never regress for this stack instead.

Usage: checkov_gate.py <checkov-results.json>
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

# Checks whose failure means a real, exploitable exposure in this design.
# Keep this list aligned with docs/RISKS.md.
HIGH_RISK_CHECKS: dict[str, str] = {
    # Network exposure
    "CKV_AWS_23": "security group rule without a description",
    "CKV_AWS_24": "ingress from 0.0.0.0/0 on port 22",
    "CKV_AWS_25": "ingress from 0.0.0.0/0 on port 3389",
    "CKV_AWS_260": "ingress from 0.0.0.0/0 on port 80",
    "CKV_AWS_382": "egress open to 0.0.0.0/0",
    "CKV_AWS_130": "subnet assigns public IPs by default",
    "CKV2_AWS_5": "security group not attached to a resource",
    "CKV2_AWS_12": "default security group allows traffic",
    "CKV2_AWS_11": "VPC flow logs disabled",
    # Storage exposure and encryption
    "CKV_AWS_18": "S3 bucket without server access logging",
    "CKV_AWS_19": "S3 bucket without server-side encryption",
    "CKV_AWS_20": "S3 bucket publicly readable",
    "CKV_AWS_21": "S3 bucket without versioning",
    "CKV_AWS_53": "S3 bucket does not block public ACLs",
    "CKV_AWS_54": "S3 bucket does not block public policy",
    "CKV_AWS_55": "S3 bucket does not ignore public ACLs",
    "CKV_AWS_56": "S3 bucket does not restrict public buckets",
    "CKV_AWS_145": "S3 bucket not encrypted with a KMS CMK",
    "CKV2_AWS_6": "S3 bucket without Public Access Block",
    # Key management
    "CKV_AWS_7": "KMS CMK without automatic rotation",
    # IAM
    "CKV_AWS_109": "IAM policy allows permissions management without constraint",
    "CKV_AWS_111": "IAM policy allows write access without constraint",
    "CKV_AWS_356": 'IAM policy allows "*" resource for restrictable actions',
}

HIGH_RISK_SEVERITIES = {"CRITICAL", "HIGH"}


def load_results(path: Path) -> tuple[list[dict], dict]:
    raw = json.loads(path.read_text())
    reports = raw if isinstance(raw, list) else [raw]

    failed: list[dict] = []
    summary: dict = {}
    for report in reports:
        results = report.get("results", {})
        failed.extend(results.get("failed_checks", []))
        summary = report.get("summary", summary)
    return failed, summary


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: checkov_gate.py <checkov-results.json>", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    if not path.is_file():
        print(f"ERROR: {path} not found - did the Checkov scan run?", file=sys.stderr)
        return 2

    failed, summary = load_results(path)

    print("Checkov summary:", json.dumps(summary))

    if not failed:
        print("High-risk gate: PASS (no failing checks)")
        return 0

    blocking = []
    for check in failed:
        check_id = check.get("check_id", "")
        severity = (check.get("severity") or "").upper()
        if check_id in HIGH_RISK_CHECKS or severity in HIGH_RISK_SEVERITIES:
            blocking.append(check)

    print(f"\nTotal failing checks: {len(failed)}")
    for check in failed:
        check_id = check.get("check_id", "")
        label = HIGH_RISK_CHECKS.get(check_id, "not in the high-risk list")
        print(f"  - {check_id} [{check.get('resource', '')}] ({label})")

    if not blocking:
        print("\nHigh-risk gate: PASS (no rule from the high-risk set failed)")
        return 0

    print("\nHigh-risk gate: FAIL")
    for check in blocking:
        print(f"  BLOCKING {check.get('check_id')} on {check.get('resource')}")
        print(f"           {check.get('file_path')}:{check.get('file_line_range')}")
    print(
        "\nFix the finding, or add a narrowly scoped inline suppression with a"
        " written justification next to the affected resource."
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
