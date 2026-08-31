"""Backend for the Handheld Control Decky plugin.

Shells out to /usr/bin/handheld-power rather than talking to D-Bus, and that is
deliberate rather than lazy:

  * PluginLoader is a frozen PyInstaller bundle. It carries only the modules
    decky-loader itself imports, so `import gi` inside a plugin backend raises
    ModuleNotFoundError — there is no PyGObject to bind to. Nor is there a
    pure-Python D-Bus client available without vendoring one.

  * handheld-power already speaks org.handheld.Power1, is installed in the image,
    and runs under the SYSTEM python where gi does exist. Reusing it means the
    CLI and this plugin cannot disagree about what a profile is, and there is one
    place to fix a bug rather than two.

So the CLI's `--json` output is the contract. It exists for this caller.

Privilege: plugin.json declares `_root` and plugin_loader.service runs as root,
which is what lets these calls through /usr/share/dbus-1/system.d/
org.handheld.Power.conf (root may own and send). A non-root plugin would need
the deck user, which is in `wheel`, so it would also work — but Decky's own
service is root and there is no reason to fight it.
"""

import asyncio
import json

import decky

CLI = "/usr/bin/handheld-power"
TIMEOUT = 10


async def _run(*args):
    """Run handheld-power and return (rc, stdout, stderr).

    Never raises on a non-zero exit: the frontend renders the error string, and
    an exception here would surface in the Steam UI as a silent dead panel.
    """
    try:
        proc = await asyncio.create_subprocess_exec(
            CLI, *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
    except OSError as exc:
        return 127, "", f"cannot execute {CLI}: {exc}"

    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout=TIMEOUT)
    except asyncio.TimeoutError:
        proc.kill()
        return 124, "", f"{CLI} {' '.join(args)} timed out after {TIMEOUT}s"

    return proc.returncode, out.decode(errors="replace"), err.decode(errors="replace")


class Plugin:

    async def _main(self):
        decky.logger.info("handheld-control: backend started")

    async def _unload(self):
        decky.logger.info("handheld-control: backend stopped")

    async def _uninstall(self):
        pass

    # ── reads ────────────────────────────────────────────────────────────────

    async def get_status(self) -> dict:
        """Everything the panel renders, in one call.

        One call rather than one per field: the panel polls while it is open, and
        a handful of round trips per tick through the loader's websocket adds up
        to visible lag on a handheld.
        """
        rc, out, err = await _run("status", "--json")
        if rc != 0:
            # The daemon not running is the common case worth naming clearly —
            # everything else is passed through as-is.
            message = err.strip() or f"handheld-power exited {rc}"
            decky.logger.warning("handheld-control: %s", message)
            return {"ok": False, "error": message}

        try:
            status = json.loads(out)
        except json.JSONDecodeError as exc:
            decky.logger.error("handheld-control: bad JSON from CLI: %s", exc)
            return {"ok": False, "error": f"could not parse handheld-power output: {exc}"}

        return {"ok": True, "status": status}

    async def get_options(self) -> dict:
        """The available choices, which only change when the config is reloaded.

        Read from `handheld-power <cmd>` listings rather than from GetStatus,
        because the daemon exposes availability as separate D-Bus properties and
        the listing already marks the active entry with `*`.
        """
        result: dict = {"ok": True, "profiles": [], "fanCurves": []}

        rc, out, _ = await _run("profile")
        if rc == 0:
            result["profiles"] = [ln[2:].strip() for ln in out.splitlines() if ln[2:].strip()]

        # A device with no fan exits non-zero here; that is not an error, it is
        # the answer, and the frontend hides the control on an empty list.
        rc, out, _ = await _run("fan")
        if rc == 0:
            result["fanCurves"] = [ln[2:].strip() for ln in out.splitlines() if ln[2:].strip()]

        return result

    # ── writes ───────────────────────────────────────────────────────────────

    async def set_profile(self, name: str) -> dict:
        rc, _, err = await _run("profile", name)
        return {"ok": rc == 0, "error": err.strip()}

    async def set_fan_curve(self, name: str) -> dict:
        # "profile" is the CLI's word for clearing the override; see cmd_fan.
        rc, _, err = await _run("fan", name)
        return {"ok": rc == 0, "error": err.strip()}

    async def set_gpu(self, value: str) -> dict:
        """`auto`, `manual`, or a clock in MHz as a string."""
        rc, _, err = await _run("gpu", value)
        return {"ok": rc == 0, "error": err.strip()}

    async def reload_config(self) -> dict:
        rc, _, err = await _run("reload")
        return {"ok": rc == 0, "error": err.strip()}
