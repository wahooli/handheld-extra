#!/usr/bin/env bash
#
# Keep exactly one open issue describing which packages are behind upstream.
#
# Edited in place rather than appended to or reopened per run: this is a status
# board, not a log. If nothing is behind, the issue is closed rather than left
# open saying "nothing to do".
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${HERE}"

command -v gh >/dev/null || { echo "!! gh not available" >&2; exit 0; }

TITLE="packages behind upstream"
report="$(cat .upstream-report.md 2>/dev/null || true)"

num="$(gh issue list --state open --search "\"${TITLE}\" in:title" \
        --json number,title --jq ".[] | select(.title == \"${TITLE}\") | .number" | head -1)"

if [ -z "${report//[[:space:]]/}" ]; then
    if [ -n "${num}" ]; then
        gh issue close "${num}" --comment "Everything is up to date as of this run."
        echo "==> closed #${num}: nothing behind"
    else
        echo "==> nothing behind, no issue to close"
    fi
    exit 0
fi

body="$(printf '%s\n\n---\n\nMaintained by `.github/workflows/poll.yml`; edited in place each run.\nClosed automatically when every package catches up.\n' "${report}")"

if [ -n "${num}" ]; then
    gh issue edit "${num}" --body "${body}"
    echo "==> updated #${num}"
else
    gh issue create --title "${TITLE}" --body "${body}"
    echo "==> opened: ${TITLE}"
fi
