# handheld-extra

Userland packages for ARM handhelds running Arch Linux ARM, built and published
as a signed pacman repository.

Companion to [`linux-handheld-aarch64`](https://github.com/wahooli/linux-handheld-aarch64),
which does the same for the kernel. Devices add both:

```
[handheld]        the kernel + headers
[handheld-extra]  everything here
```

## Packages

| Package | Tracks |
|---|---|
| `gamescope` | the OpenGamingCollective fork, plus armada's 13 handheld patches |
| `mangohud` | upstream releases |
| `hyprgrass` | upstream, pinned against a Hyprland version |
| `wvkbd` | upstream, plus a Finnish layout patch |
| `inputplumber` | armada's pin of ShadowBlip/InputPlumber, plus 3 patches |
| `umtp-responder` | armada's pin of viveris/uMTP-Responder, plus 5 patches |
| `decky-loader` | upstream releases |
| `decky-plugin-emudecky` | upstream releases |
| `decky-plugin-handheld-control` | first-party — fan curve and thermals over `org.handheld.Power1` |

## Building

Requires an aarch64 host with docker.

```sh
./scripts/build.sh wvkbd mangohud     # named packages
./scripts/build.sh --all              # everything
./scripts/build.sh --changed HEAD~1   # only what changed — what CI uses
ls out/
```

Each package builds in its own subshell, so one failure does not stop the rest;
failures are collected and reported at the end.

`--changed` is why `build.yml` checks out with `fetch-depth: 2` — it diffs
package directories against the previous commit, and a depth-1 clone has no
previous commit to diff against.

Note that a change *outside* `packages/` — a script, the Dockerfile — rebuilds
nothing. Those change how packages are built, not what they contain.

## Publishing

```sh
./scripts/publish-r2.sh                       # sign, repo-add, upload, prune
CHECK_ONLY=1 ./scripts/publish-r2.sh          # just prove the credentials work
DRY_RUN=1 ./scripts/publish-r2.sh             # everything except writing to R2
REPO_URL=https://arch-repo.wahoo.li ./scripts/verify-repo.sh
```

Identity lives in `repo.env`, so the scripts and the workflows cannot disagree
about which database they are writing.

Secrets are the same six as the kernel repo, including the same
`REPO_SIGNING_KEY` — one trust anchor per device, added once.

## Build directories

`scripts/build-in-container.sh` sets `BUILDDIR` and `SRCDEST` so makepkg keeps
its scratch trees out of `packages/`. That is load-bearing, not tidiness. Left at
their defaults, a PKGBUILD with a `git+https://` source clones straight into its
own package directory — `hyprgrass` gets a bare `hyprgrass/` checkout, and
`gamescope` grows seven of them. Two things then break:

- `git add -A` after a local build commits an entire vendored upstream tree.
- `build.sh --changed` decides what to rebuild by asking whether a package
  directory changed, so build output inside one makes it permanently dirty and
  every build rebuilds everything.

It does not cover everything. `decky-plugin-handheld-control` is first-party and
has an empty `source=()`, so it builds from `$startdir` — `pnpm` writes
`node_modules/`, `dist/` and a lockfile straight into the package directory no
matter where makepkg puts its own scratch. Those have explicit `.gitignore`
rules; any future first-party package will need the same.

What deliberately has **no** rule is `packages/*/src/`. That would catch build
output for most packages and silently drop
`decky-plugin-handheld-control/src/`, which is first-party TypeScript that has
to be committed.

## Adding a package

Drop a directory under `packages/` containing a `PKGBUILD` (and `patches/` if it
needs any). `build.sh --all` and the change detection pick it up with no other
edit — there is no package list to maintain.
