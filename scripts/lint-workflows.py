#!/usr/bin/env python3
"""Validate the workflow files."""
import glob
import re
import sys

import yaml

OPEN = "$" + "{{"
CLOSE = "}" + "}"
EXPR = re.compile(re.escape(OPEN) + r".*?" + re.escape(CLOSE))
IF_LINE = re.compile(r"\s*if:\s*(.+?)\s*$")

def main() -> int:
    files = sorted(glob.glob(".github/workflows/*.yml"))
    if not files:
        print("no workflow files found", file=sys.stderr)
        return 1

    bad = 0
    for path in files:
        try:
            yaml.safe_load(open(path))
        except Exception as exc:
            print(f"::error file={path}::invalid YAML: {exc}")
            bad += 1
            continue

        for num, line in enumerate(open(path), 1):
            match = IF_LINE.match(line)
            if not match:
                continue
            value = match.group(1)
            if OPEN not in value:
                continue
            outside = EXPR.sub("", value).strip()
            if outside:
                print(
                    f"::error file={path},line={num}::mixed conditional: "
                    f"{outside!r} sits outside the braces and is ignored. "
                    f"Put the whole condition inside a single expression."
                )
                bad += 1

        print(f"ok   {path}")

    if bad:
        print(f"{bad} problem(s)")
        return 1
    print(f"{len(files)} workflow(s) valid, no mixed conditionals")
    return 0

if __name__ == "__main__":
    sys.exit(main())
