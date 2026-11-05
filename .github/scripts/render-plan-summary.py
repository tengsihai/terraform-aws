#!/usr/bin/env python3
"""Render `terraform show -json` output as a Markdown plan summary.

The summary is used both as a sticky pull-request comment and as a GitHub
Actions step summary. It intentionally shows counts and a bounded resource
table rather than the full plan: the authoritative artifact is the `.tfplan`
file, and the summary must stay under the comment size limit.

Usage:
    render-plan-summary.py --plan-json plan.json --environment prod \
        --commit "$GITHUB_SHA" --run-url "$RUN_URL" \
        --artifact terraform-plan-prod --output summary.md
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

# Actions are reported by Terraform as a list. Only these shapes are meaningful.
ACTION_LABELS = {
    ("create",): "create",
    ("update",): "update",
    ("delete",): "delete",
    ("delete", "create"): "replace",
    ("create", "delete"): "replace",
    ("read",): "read",
    ("no-op",): "no-op",
}

DESTRUCTIVE = {"delete", "replace"}

MAX_TABLE_ROWS = 60
MAX_BYTES = 60_000


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan-json", required=True, type=Path)
    parser.add_argument("--environment", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--run-url", required=True)
    parser.add_argument("--artifact", required=True)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def action_label(actions: list[str]) -> str:
    key = tuple(actions)
    if key in ACTION_LABELS:
        return ACTION_LABELS[key]
    # Unknown shape: describe it rather than silently dropping the resource.
    return "+".join(actions) or "unknown"


def collect_changes(plan: dict) -> list[dict]:
    changes = []
    for entry in plan.get("resource_changes", []):
        if entry.get("mode", "managed") != "managed":
            continue
        actions = entry.get("change", {}).get("actions", [])
        label = action_label(actions)
        if label == "no-op":
            continue
        changes.append(
            {
                "address": entry.get("address", "?"),
                "type": entry.get("type", "?"),
                "module": entry.get("module_address", "(root)"),
                "action": label,
            }
        )
    return changes


def render(args: argparse.Namespace, plan: dict, changes: list[dict]) -> str:
    counts = Counter(change["action"] for change in changes)
    create = counts.get("create", 0)
    update = counts.get("update", 0)
    delete = counts.get("delete", 0)
    replace = counts.get("replace", 0)
    read = counts.get("read", 0)

    destructive = [c for c in changes if c["action"] in DESTRUCTIVE]
    outputs_changed = sum(
        1
        for change in plan.get("output_changes", {}).values()
        if change.get("actions") not in (["no-op"], ["read"], [])
    )

    lines: list[str] = []
    lines.append(f"<!-- terraform-plan:{args.environment} -->")
    lines.append(f"## Terraform plan — `{args.environment}`")
    lines.append("")

    if not changes and not outputs_changed:
        lines.append("**No infrastructure changes.** The plan matches the deployed state.")
    else:
        lines.append(
            f"**{create} to add, {update} to change, {delete} to destroy, "
            f"{replace} to replace**"
        )
    lines.append("")
    lines.append(f"- Commit: `{args.commit[:12]}`")
    lines.append(f"- Artifact: `{args.artifact}` ([plan run]({args.run_url}))")
    lines.append(f"- Resources in plan: {len(changes)}")
    if outputs_changed:
        lines.append(f"- Output values changing: {outputs_changed}")
    if read:
        lines.append(f"- Data sources read during plan: {read}")
    lines.append("")

    if destructive:
        lines.append("> [!WARNING]")
        lines.append(
            f"> This plan **destroys or replaces {len(destructive)} resource(s)**. "
            "Confirm each one is intended before approving the apply."
        )
        lines.append("")
        for change in destructive:
            lines.append(f"> - `{change['action']}` {change['address']}")
        lines.append("")

    if changes:
        lines.append("<details><summary>Resource changes</summary>")
        lines.append("")
        lines.append("| Action | Resource | Module |")
        lines.append("| --- | --- | --- |")
        for change in changes[:MAX_TABLE_ROWS]:
            lines.append(
                f"| `{change['action']}` | `{change['address']}` | `{change['module']}` |"
            )
        if len(changes) > MAX_TABLE_ROWS:
            lines.append(
                f"| … | *{len(changes) - MAX_TABLE_ROWS} more, see the plan artifact* | |"
            )
        lines.append("")
        lines.append("</details>")
        lines.append("")

    lines.append("---")
    lines.append(
        "Approval is a manual step: a reviewer checks this plan against "
        "`docs/PLAN-CHECKLIST.md`, then dispatches **Terraform apply** with this "
        "run's ID. The apply job applies this exact plan file — it does not re-plan."
    )

    body = "\n".join(lines) + "\n"
    if len(body.encode()) > MAX_BYTES:
        body = body.encode()[:MAX_BYTES].decode(errors="ignore")
        body += "\n\n*Summary truncated. See the plan artifact for the full diff.*\n"
    return body


def main() -> int:
    args = parse_args()

    try:
        plan = json.loads(args.plan_json.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        print(f"ERROR: cannot read plan JSON: {exc}", file=sys.stderr)
        return 1

    if not plan.get("complete", True):
        print("WARNING: the plan is incomplete; reporting what is available", file=sys.stderr)

    body = render(args, plan, collect_changes(plan))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(body)
    print(f"wrote {args.output} ({len(body.encode())} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
