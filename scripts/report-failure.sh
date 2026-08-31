#!/usr/bin/env bash
#
# Open (or comment on) the build-failure issue. Deduped by title.
# Needs GH_TOKEN; RUN_URL is a link back to the logs.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${HERE}"
# shellcheck source=/dev/null
source ./repo.env

command -v gh >/dev/null || { echo "!! gh not available" >&2; exit 0; }

title="build failed: ${REPO_NAME} run ${RUN_NUMBER:-?}"
body="$(cat <<BODY
${RUN_URL:-(no run url)}

The database was only touched if the failure happened during publish; otherwise
devices keep whatever \`[${REPO_NAME}]\` currently serves.

**One package failing does not stop the others.** \`makepkg-each.sh\` builds each
package in its own subshell and collects failures at the end, so the rest of the
run was still built and published. The job summary lists what came out.

Common causes here, in rough order of likelihood:

- **An upstream moved and the PKGBUILD did not.** These packages track other
  people's releases; a changed tarball checksum or a renamed source is the usual
  reason a package that built last week stops building.
- **A patch stopped applying.** \`gamescope-virtio\` and \`wvkbd\` carry patches;
  those are the two that can break on an upstream bump without any change here.
- **A new makedepend.** \`makepkg --syncdeps\` installs them, so this shows up as
  a missing-package error rather than a compile error.
BODY
)"

existing="$(gh issue list --state open --search "\"${title}\" in:title" \
              --json number,title \
              --jq ".[] | select(.title == \"${title}\") | .number" | head -1)"

if [ -n "${existing}" ]; then
    gh issue comment "${existing}" --body "${body}"
    echo "==> commented on issue #${existing}"
else
    gh issue create --title "${title}" --body "${body}"
    echo "==> opened issue: ${title}"
fi
