#!/usr/bin/env bash
# Compiles src/launchOptions.ts on its own and runs the parser checks under
# node, with @decky/ui stubbed: the module only needs Router at import time.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "${out}"' EXIT
mkdir -p "${out}/node_modules/@decky/ui"
echo 'module.exports = { Router: {} };' > "${out}/node_modules/@decky/ui/index.js"
# Alone, tsc reports the Decky globals (window, SteamClient) as type errors but
# still emits the JS, so its status is not the signal; the output file is.
"${here}/node_modules/.bin/tsc" --outDir "${out}" --module commonjs --target es2020 \
    --skipLibCheck --esModuleInterop "${here}/src/launchOptions.ts" >/dev/null || true
[ -f "${out}/launchOptions.js" ] || { echo "launchOptions.ts did not compile" >&2; exit 1; }
cp "${here}/test/launchOptions.test.cjs" "${out}/"
cd "${out}" && node -e 'globalThis.window = {}; require("./launchOptions.test.cjs")'
