#!/usr/bin/env python3
"""Fail when a planned taggable resource is missing one of the base tags.

Reads `terraform show -json <plan>` from stdin. Resources are considered
taggable when the plan exposes `tags_all` (provider default_tags merged with the
resource's own tags) or an Auto Scaling group `tag` block list.

Usage:
  terraform -chdir=environments/dev show -json reports/dev/plan.tfplan \\
    | python3 scripts/check-tags.py
"""

from __future__ import annotations

import json
import sys

REQUIRED = ("Project", "Environment", "ManagedBy", "Repository")


def main() -> int:
    try:
        document = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print(f"ERROR: stdin is not valid plan JSON: {exc}", file=sys.stderr)
        return 2

    root = document.get("planned_values", {}).get("root_module")
    if root is None:
        print("ERROR: no planned_values.root_module in input", file=sys.stderr)
        return 2

    problems: list[tuple[str, list[str]]] = []
    checked = 0

    def walk(module: dict) -> None:
        nonlocal checked

        for resource in module.get("resources", []):
            values = resource.get("values") or {}
            tags_all = values.get("tags_all")

            if isinstance(tags_all, dict):
                checked += 1
                missing = [key for key in REQUIRED if not str(tags_all.get(key) or "").strip()]
                if missing:
                    problems.append((resource["address"], missing))
                continue

            tag_blocks = values.get("tag")
            if isinstance(tag_blocks, list) and tag_blocks:
                checked += 1
                as_map = {
                    block.get("key"): block.get("value")
                    for block in tag_blocks
                    if isinstance(block, dict)
                }
                missing = [key for key in REQUIRED if not str(as_map.get(key) or "").strip()]
                if missing:
                    problems.append((resource["address"], missing))

        for child in module.get("child_modules", []):
            walk(child)

    walk(root)

    if problems:
        print(
            f"Tag compliance: FAIL ({len(problems)} of {checked} taggable resources missing base tags)",
            file=sys.stderr,
        )
        for address, missing in problems:
            print(f"  {address}: missing {', '.join(missing)}", file=sys.stderr)
        return 1

    print(f"Tag compliance: PASS ({checked} taggable resources carry {', '.join(REQUIRED)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
