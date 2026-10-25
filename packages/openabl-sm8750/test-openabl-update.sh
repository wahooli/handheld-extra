#!/usr/bin/env bash
# openabl-update against fake partitions: what it writes, and what it refuses.
# Run from check(): bash test-openabl-update.sh ./openabl-update
set -uo pipefail
updater=$(readlink -f "${1:?usage: test-openabl-update.sh <openabl-update>}")
t=$(mktemp -d)
trap 'rm -rf "${t}"' EXIT
fails=0
ok() { echo "  ok: $1"; }
bad() { echo "  FAIL: $1" >&2; fails=$((fails + 1)); }
expect() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

# Three releases and a stock ABL. 1.2 is a different size, as a real one may be.
for v in 1.0 1.1 stock; do head -c 8192 /dev/urandom > "${t}/${v}"; done
head -c 12288 /dev/urandom > "${t}/1.2"
mkdir -p "${t}/lib"
cp "${t}/1.1" "${t}/lib/abl_signed-SM8750.elf"
{
    printf '# version\tsize\tsha256\n'
    for v in 1.0 1.1 1.2; do
        printf '%s\t%s\t%s\n' "${v}" "$(stat -c %s "${t}/${v}")" "$(sha256sum "${t}/${v}" | cut -d' ' -f1)"
    done
} > "${t}/lib/releases.tsv"
printf 'ayn,odin3\0qcom,sm8750\0' > "${t}/compatible"

slots() {  # slots <abl_a content> <abl_b content>: 64 KiB partitions
    head -c 65536 /dev/zero > "${t}/abl_a"; dd if="${t}/$1" of="${t}/abl_a" conv=notrunc status=none
    head -c 65536 /dev/zero > "${t}/abl_b"; dd if="${t}/$2" of="${t}/abl_b" conv=notrunc status=none
}
run() {
    OPENABL_DIR="${t}/lib" OPENABL_COMPATIBLE="${t}/compatible" OPENABL_LOCK="${t}/lock" \
        OPENABL_ABL_A="${t}/abl_a" OPENABL_ABL_B="${t}/abl_b" OPENABL_ALLOW_FILES=1 \
        "${updater}" "$@" > "${t}/out" 2>&1
    echo $?
}
holds() {  # holds <slot> <content>
    if cmp -s -n "$(stat -c %s "${t}/$2")" "${t}/abl_$1" "${t}/$2"; then echo "$2"; else echo other; fi
}

slots 1.0 1.0
expect "$(run --check)" 0 "--check exits 0"
expect "$(holds a 1.0)" 1.0 "--check writes nothing"
expect "$(run)" 0 "an older OpenABL is updated"
expect "$(holds a 1.1)/$(holds b 1.1)" 1.1/1.1 "both slots now hold the payload"
expect "$(run)" 0 "a second run exits 0"
grep -q "already" "${t}/out" && ok "a second run has nothing to do" || bad "a second run has nothing to do"

slots 1.1 1.0
run > /dev/null
expect "$(holds a 1.1)/$(holds b 1.1)" 1.1/1.1 "one stale slot is brought up to date"

slots stock 1.0
expect "$(run)" 1 "a stock ABL is refused"
expect "$(holds a stock)/$(holds b 1.0)" stock/1.0 "and neither slot is touched"

slots 1.0 stock
expect "$(run)" 1 "a stock ABL in abl_b is refused"
expect "$(holds a 1.0)" 1.0 "and abl_a is not written first"

slots 1.2 1.2
expect "$(run)" 1 "a newer OpenABL is refused"
expect "$(holds a 1.2)" 1.2 "and is left in place"

slots 1.0 1.0
printf 'qcom,x1e80100\0' > "${t}/compatible"
expect "$(run)" 0 "another SoC is a quiet no-op"
expect "$(holds a 1.0)" 1.0 "and writes nothing"
printf 'qcom,sm8750\0' > "${t}/compatible"

if [ "$(id -u)" -ne 0 ]; then  # root reads it regardless
    slots 1.0 1.0
    chmod 000 "${t}/abl_a"
    expect "$(run --check)" 1 "an unreadable slot is an error"
    grep -q "run as root" "${t}/out" && ok "that says to run as root" || bad "that says to run as root"
    chmod 644 "${t}/abl_a"
fi

cp "${t}/stock" "${t}/lib/abl_signed-SM8750.elf"
expect "$(run)" 1 "a payload missing from the catalog is refused"
expect "$(holds a 1.0)" 1.0 "and writes nothing"

[ "${fails}" -eq 0 ] && echo "openabl-update: all checks passed"
exit "${fails}"
