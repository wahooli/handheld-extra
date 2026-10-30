import asyncio
import json
import os

import decky

# The Decky backend cannot use D-Bus (PluginLoader is a frozen bundle with no
# `gi`), so handheld-settingsd is reached through its CLI, as Handheld Control
# does; `status --json` is the contract.
SETTINGS_CLI = "/usr/bin/handheld-settings"
# Leaving mouse mode waits up to 3 s for the cursor to stop.
TIMEOUT = 20
COMMANDS = {"touch": "touch-area", "dpad": "dpad"}
STATUS_KEYS = {"touch": "TouchAreaMode", "dpad": "DpadMode"}
# {"default": {kind: mode}, "games": {appid: {kind: mode}}}
PROFILES_FILE = os.path.join(decky.DECKY_PLUGIN_SETTINGS_DIR, "per-game.json")


async def _settings(*args):
    try:
        proc = await asyncio.create_subprocess_exec(
            SETTINGS_CLI, *args,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    except OSError as exc:
        return None, f"cannot execute {SETTINGS_CLI}: {exc}"
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout=TIMEOUT)
    except asyncio.TimeoutError:
        proc.kill()
        return None, f"handheld-settings {' '.join(args)} timed out"
    if proc.returncode != 0:
        return None, err.decode(errors="replace").strip() or f"handheld-settings exited {proc.returncode}"
    return out.decode(errors="replace"), None


async def _status():
    out, error = await _settings("status", "--json")
    if out is None:
        return None, error
    try:
        return json.loads(out), None
    except json.JSONDecodeError as exc:
        return None, f"could not parse handheld-settings: {exc}"


def _choice(status, key):
    options = status.get(f"{key}s") or []
    return {"current": status.get(key, ""), "options": options} if options else None


def _load_profiles():
    try:
        with open(PROFILES_FILE) as f:
            data = json.load(f)
    except (OSError, ValueError):
        data = {}
    if not isinstance(data, dict):
        data = {}
    data.setdefault("default", {})
    data.setdefault("games", {})
    return data


def _save_profiles(data):
    os.makedirs(os.path.dirname(PROFILES_FILE), exist_ok=True)
    tmp = f"{PROFILES_FILE}.tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
    os.replace(tmp, PROFILES_FILE)


class Plugin:
    def __init__(self):
        self._game = None  # appid of the running game, as Steam reported it

    def _active(self, data):
        """The profile in force: the running game's own, else the default."""
        if self._game and self._game in data["games"]:
            return data["games"][self._game]
        return data["default"]

    async def _apply(self, profile):
        """Set each mode the profile names that the MCU is not already in."""
        status, error = await _status()
        if status is None:
            return error
        errors = []
        for kind, mode in profile.items():
            if kind in COMMANDS and status.get(STATUS_KEYS[kind]) != mode:
                out, error = await _settings(COMMANDS[kind], mode)
                if out is None:
                    errors.append(f"{kind} {mode}: {error}")
        if errors:
            decky.logger.warning("; ".join(errors))
        return "; ".join(errors) or None

    async def get_modes(self, appid: str = "") -> dict:
        status, error = await _status()
        if status is None:
            return {"ok": False, "error": error}
        data = _load_profiles()
        if not data["default"]:
            # First run: the modes in use become the default profile.
            data["default"] = {k: status[v] for k, v in STATUS_KEYS.items() if status.get(v)}
            _save_profiles(data)
        return {"ok": True, "touch": _choice(status, "TouchAreaMode"), "dpad": _choice(status, "DpadMode"),
                "per_game": bool(appid) and appid in data["games"]}

    async def set_mode(self, kind: str, mode: str) -> dict:
        """Change a mode in the profile in force, and apply it."""
        if kind not in COMMANDS:
            return {"ok": False, "error": f"{kind!r} is not a controller mode"}
        data = _load_profiles()
        self._active(data)[kind] = mode
        _save_profiles(data)
        error = await self._apply({kind: mode})
        return {"ok": error is None, "error": error}

    async def set_per_game(self, appid: str, enabled: bool) -> dict:
        """Give a game its own profile, starting from the default, or drop it."""
        data = _load_profiles()
        if enabled:
            data["games"].setdefault(appid, dict(data["default"]))
        else:
            data["games"].pop(appid, None)
        _save_profiles(data)
        error = await self._apply(self._active(data)) if appid == self._game else None
        return {"ok": error is None, "error": error}

    async def game_started(self, appid: str) -> dict:
        self._game = appid
        error = await self._apply(self._active(_load_profiles()))
        return {"ok": error is None, "error": error}

    async def game_stopped(self, appid: str) -> dict:
        if self._game != appid:
            return {"ok": True, "error": None}
        self._game = None
        error = await self._apply(_load_profiles()["default"])
        return {"ok": error is None, "error": error}

    async def _main(self):
        pass

    async def _unload(self):
        pass
