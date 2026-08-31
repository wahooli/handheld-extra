#!/usr/bin/env python3
"""Validate the workflow files.

Lives in a script rather than inline in check.yml, and that is not a style
preference. GitHub scans the ENTIRE workflow file for ${{ ... }} sequences --
including inside run: block scalars -- and tries to parse each one as an
expression. A linter that looks for mixed conditionals necessarily contains the
literal characters it is searching for, so writing it inline makes the workflow
itself invalid:

    Invalid workflow file: The expression is not closed. An unescaped ${{
    sequence was found, but the closing }} sequence was not found.

Two checks:

  1. Every workflow parses as YAML.

  2. No `if:` mixes an expression with literal text. `if: <expr> && B`, where
     <expr> is wrapped in braces and B is not, makes GitHub evaluate the whole
     value as a STRING -- always truthy -- so B is silently ignored. That cost
     this repo a run in which two cache-save steps re-uploaded 700 MB they had
     just restored, because their cache-hit guard was being discarded. It shows
     up only as a workflow annotation after a push, which is too late.
"""
import glob
import re
import sys

import yaml

# Built rather than written literally, so this file never contains the sequence
# it looks for -- otherwise it could not be pasted back into a workflow, and
# grepping the repo for the bug would match the linter itself.
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
        except Exception as exc:                       # noqa: BLE001
            print(f"::error file={path}::invalid YAML: {exc}")
            bad += 1
            continue

        for num, line in enumerate(open(path), 1):
            match = IF_LINE.match(line)
            if not match:
                continue
            value = match.group(1)
            if OPEN not in value:
                continue                               # plain expression, fine
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
