# decky-loader

Decky Loader, built natively for aarch64.

## Why this exists

Upstream publishes one Linux asset per release and it is x86-64:

```
$ curl -r 0-63 <PluginLoader release asset> | xxd
magic: \x7fELF        e_machine: 0x3e  (x86-64)
```

Armada runs that binary under host FEX, which is why their image ships
`fex-emu`, a FEX guest rootfs squashfs, and a
`/usr/share/fex-emu/AppConfig/PluginLoader.json` tuned for it. This repo has no
host FEX — ours only exists inside Proton, for Windows games — so carrying that
whole subsystem to run one Python daemon would be absurd.

It turns out not to be necessary. Nothing in decky-loader is
architecture-specific: the frontend is TypeScript, the backend is Python, and
PyInstaller freezes whichever interpreter it is pointed at. The only reason no
arm64 asset exists is that upstream's workflow had no arm64 runner.

## Delete this package when #914 merges

[decky-loader#914](https://github.com/SteamDeckHomebrew/decky-loader/pull/914)
adds exactly that runner. It is **open, approved and mergeable**, from
`giodotblue/decky-loader`, and the workflow it calls is arch-agnostic —
`runs-on: ${{ inputs.arch == 'arm64' && 'ubuntu-24.04-arm' || 'ubuntu-22.04' }}`
and otherwise identical to the x86-64 job.

When it lands, upstream will publish `PluginLoader-arm64` and this entire
directory should be replaced by a download. Everything here is a stand-in for a
CI job upstream is about to run itself.

## The one real gotcha

`backend/pyproject.toml` declares:

```toml
python = ">=3.10,<3.14"
```

ALARM ships Python **3.14**. That cap is why the upstream workflow pins 3.11.7,
and it is the only thing standing between this and a clean build. It is
metadata, not a real incompatibility — verified on aarch64 + cp314:

```
aiohttp 3.14.3    multidict 6.7.1    setproctitle 1.3.7
watchdog 6.0.0    pyinstaller 6.22.2 (claims support through 3.15)
```

`prepare()` widens it to `<3.16` and asserts the substitution took, so an
upstream change to that line fails the build loudly rather than silently
building against an unpatched constraint.

The alternative — carrying AUR `python311` or a standalone CPython purely to
satisfy a bound nothing enforces at runtime — is the worse trade. If a future
Decky release genuinely breaks on 3.14, that `sed` is where it should start
failing.

## Second gotcha, if you ever rework `build()`

`pyinstaller.spec` calls `copy_metadata('decky_loader')`, which reads *installed
distribution metadata*. Installing the dependencies is not enough — the project
itself has to be pip-installed, or the build dies inside the spec file with:

```
importlib.metadata.PackageNotFoundError: No package metadata was found for decky_loader
```

which points at nothing useful. Upstream gets this from `poetry install`; here
`pip install .` does it, and also resolves the `poetry-dynamic-versioning` build
backend that reads the version from the git tag. That is why `source=` pins a
tag rather than a commit.

## Verified

```
PluginLoader   18 MB   e_machine 0xb7 (aarch64)   reports v3.2.8-pre1
```

`build()` asserts the architecture before packaging, because a PluginLoader for
the wrong arch is exactly the bug this package exists to prevent and it is
invisible until the service fails to start on the device.

## Runtime, which is not in this package

Building the loader is the easy half.

- `/usr/lib/handheld/decky-sync` seeds `~/homebrew` at boot (the tree must be
  writable — Decky self-updates and installs plugins into it) and creates the
  **CEF remote-debugging marker**, without which Decky attaches to nothing and
  never appears in the UI. That marker is the most likely cause if the loader
  starts cleanly and is invisible.
- `plugin_loader.service` is upstream's unit with `${HOMEBREW_FOLDER}` resolved.
- `build_files/45-decky.sh` installs the package and enables both units, gated
  on `ENABLE_DECKY` in the profile.

## Version pin

`_tag=v3.2.8-pre1` — a prerelease on purpose. Decky's Steam-on-ARM fixes land on
the prerelease channel first, and `decky-sync` defaults new installs to
`"branch": 1` for the same reason. Armada does likewise.
