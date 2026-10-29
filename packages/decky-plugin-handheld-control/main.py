import asyncio
import glob
import json
import os
import re

import decky

CLI = "/usr/bin/handheld-power"
SETTINGS_CLI = "/usr/bin/handheld-settings"
SETTINGS_NAME = "org.handheld.Settings"
SETTINGS_PATH = "/org/handheld/Settings"
TIMEOUT = 10
GAMES_FILE = os.path.join(decky.DECKY_PLUGIN_SETTINGS_DIR, "per-game.json")
FRAME_CAPS_FILE = os.path.join(decky.DECKY_PLUGIN_SETTINGS_DIR, "frame-caps.json")
TUNING_FILE = os.path.join(decky.DECKY_PLUGIN_SETTINGS_DIR, "game-tuning.json")
SHADERS_FILE = os.path.join(decky.DECKY_PLUGIN_SETTINGS_DIR, "game-shaders.json")
SHADER_CLI = "/usr/bin/handheld-shader"
GAME_NICE_RANGE = (-20, 0)
MAX_FRAME_CAP = 240
REFRESH_ENV = "HANDHELD_REFRESH_RATE"
SYSTEM_PYTHON = "/usr/bin/python3"
LSFG_HELPER = os.path.join(decky.DECKY_PLUGIN_DIR, "py_modules", "lsfg_config.py")
BUSCTL = "/usr/bin/busctl"
STEAM_ROOTS = (".local/share/Steam", ".steam/steam", ".steam/debian-installation")
FEX_STEAM_CONFIG = "proton-fex-config.json"
FEX_BUILTIN = {
    "TSOEnabled": "1", "VectorTSOEnabled": "0", "MemcpySetTSOEnabled": "0",
    "HalfBarrierTSOEnabled": "1", "X87ReducedPrecision": "0", "Multiblock": "1",
    "VolatileMetadata": "1", "SMCChecks": "mtrack", "StrictInProcessSplitLocks": "0",
    "MaxInst": "5000", "MonoHacks": "1", "HideHypervisorBit": "0",
}
SMC_NAMES = {"0": "none", "1": "mtrack", "2": "full"}
CPU_SYS = "/sys/devices/system/cpu"
SCX_DOMAIN_SCHEDULER = "scx_cosmos"
SCX_NAME = "org.scx.Loader"
SCX_PATH = "/org/scx/Loader"
SCX_NONE = "unknown"
SCX_MODES = ("Auto", "Gaming", "PowerSave", "LowLatency", "Server")
SCX_MODE_FOR = {"scx_lavd": SCX_MODES.index("Gaming")}

async def _exec(*argv, env=None, data=None):
    try:
        proc = await asyncio.create_subprocess_exec(
            *argv,
            stdin=asyncio.subprocess.PIPE if data is not None else None,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=env,
        )
    except OSError as exc:
        return 127, "", f"cannot execute {argv[0]}: {exc}"

    try:
        out, err = await asyncio.wait_for(proc.communicate(data), timeout=TIMEOUT)
    except asyncio.TimeoutError:
        proc.kill()
        return 124, "", f"{' '.join(argv)} timed out after {TIMEOUT}s"

    return proc.returncode, out.decode(errors="replace"), err.decode(errors="replace")

async def _run(*args):
    return await _exec(CLI, *args)

async def _lsfg(*args):
    env = {**os.environ, "HOME": decky.DECKY_USER_HOME}
    rc, out, err = await _exec(SYSTEM_PYTHON, LSFG_HELPER, *args, env=env)
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return {"ok": False, "error": err.strip() or f"lsfg-vk config helper exited {rc}"}

async def _bus(*args):
    rc, out, err = await _exec(BUSCTL, "--json=short", "--", "call", *args)
    if rc != 0:
        return None, err.strip() or f"busctl exited {rc}"
    if not out.strip():
        return [], None
    try:
        return json.loads(out)["data"], None
    except (json.JSONDecodeError, KeyError, TypeError) as exc:
        return None, f"could not parse busctl output: {exc}"

async def _scx(method, *args):
    return await _bus(SCX_NAME, SCX_PATH, SCX_NAME, method, *args)

async def _scx_props():
    data, error = await _bus(SCX_NAME, SCX_PATH, "org.freedesktop.DBus.Properties", "GetAll", "s", SCX_NAME)
    if data is None:
        return None, error
    try:
        return {key: value["data"] for key, value in data[0].items()}, None
    except (IndexError, KeyError, TypeError, AttributeError) as exc:
        return None, f"could not parse scx_loader properties: {exc}"

async def _scx_available():
    for method in ("ListActivatableNames", "ListNames"):
        data, _ = await _bus("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", method)
        if data and SCX_NAME in data[0]:
            return True
    return False

def _scx_current(props):
    current = props.get("CurrentScheduler", SCX_NONE)
    return "" if current == SCX_NONE else current

def _parse_cpulist(text):
    cpus = set()
    for part in str(text).replace(" ", ",").split(","):
        if not part:
            continue
        low, _, high = part.partition("-")
        start, end = int(low), int(high or low)
        if end < start:
            raise ValueError(f"{part!r} is not a CPU range")
        cpus.update(range(start, end + 1))
    return sorted(cpus)

def _format_cpulist(cpus):
    runs = []
    for cpu in sorted(set(cpus)):
        if runs and cpu == runs[-1][1] + 1:
            runs[-1][1] = cpu
        else:
            runs.append([cpu, cpu])
    return ",".join(f"{a}-{b}" if b > a else str(a) for a, b in runs)

def _read(path):
    with open(path) as f:
        return f.read().strip()

def _online_cpus():
    try:
        return _parse_cpulist(_read(f"{CPU_SYS}/online"))
    except (OSError, ValueError):
        return list(range(os.cpu_count() or 1))

def _cpu_clusters():
    clusters = {}
    for policy in sorted(glob.glob(f"{CPU_SYS}/cpufreq/policy*")):
        try:
            cpus = tuple(_parse_cpulist(_read(f"{policy}/related_cpus")))
            mhz = int(_read(f"{policy}/cpuinfo_max_freq")) // 1000
        except (OSError, ValueError):
            continue
        if cpus:
            clusters[cpus] = mhz
    return [{"cpus": list(cpus), "maxMhz": mhz} for cpus, mhz in sorted(clusters.items())]

def _scx_args(name, cores):
    if name != SCX_DOMAIN_SCHEDULER or not cores:
        return None
    try:
        pinned = set(_parse_cpulist(cores))
    except ValueError:
        return None
    online = _online_cpus()
    rest = [cpu for cpu in online if cpu not in pinned]
    if not rest or len(rest) == len(online):
        return None
    return ["--primary-domain", _format_cpulist(rest)]

def _scx_domain(args):
    if "--primary-domain" in args[:-1]:
        return args[args.index("--primary-domain") + 1]
    return ""

def _scx_mode_name(mode):
    return SCX_MODES[mode] if isinstance(mode, int) and 0 <= mode < len(SCX_MODES) else str(mode)

async def _scx_switch(name, cores=None):
    props, error = await _scx_props()
    if props is None:
        return error
    args = _scx_args(name, cores)
    mode = SCX_MODE_FOR.get(name, props.get("DefaultMode", 0))
    running_args = props.get("CurrentSchedulerArgs") or []
    if name == _scx_current(props):
        if not name:
            return ""
        if args is not None and running_args == args:
            return ""
        if args is None and not running_args and props.get("SchedulerMode") == mode:
            return ""
    if not name:
        _, error = await _scx("StopScheduler")
        return error or ""
    if name not in props.get("SupportedSchedulers", []):
        return f"{name} is not a scheduler scx_loader knows"
    if args is not None:
        _, error = await _scx("SwitchSchedulerWithArgs", "sas", name, str(len(args)), *args)
    else:
        _, error = await _scx("SwitchScheduler", "su", name, str(mode))
    return error or ""

async def _status():
    rc, out, err = await _run("status", "--json")
    if rc != 0:
        return None, err.strip() or f"handheld-power exited {rc}"
    try:
        return json.loads(out), None
    except json.JSONDecodeError as exc:
        return None, f"could not parse handheld-power output: {exc}"

def _capture_cpu(status):
    if status.get("CpuPerformanceLevel") != "manual":
        return "auto"
    pins = [f"{k.split('.', 1)[1]}={v}" for k, v in sorted(status.items())
            if k.startswith("ManualCpuClock.") and v]
    if pins:
        return ",".join(pins)
    return str(status["ManualCpuClock"]) if status.get("ManualCpuClock") else "auto"

def _capture_fan(status):
    if not status.get("HasFan"):
        return None
    if status.get("FanCurveSource") == "override" and status.get("FanCurve"):
        return status["FanCurve"]
    return "profile"

PER_GAME = {
    "cpu": _capture_cpu,
    "fan": _capture_fan,
}

async def _capture():
    status, error = await _status()
    if status is None:
        return None, error
    captured = {}
    for key, capture in PER_GAME.items():
        value = capture(status)
        if value is not None:
            captured[key] = value
    props, _ = await _scx_props()
    if props is not None:
        captured["scheduler"] = _scx_current(props)
    return captured, None

async def _apply(settings, cores=None):
    errors = []
    for key in PER_GAME:
        value = settings.get(key)
        if value is None:
            continue
        rc, _, err = await _run(key, value)
        if rc != 0:
            errors.append(err.strip() or f"handheld-power {key} {value} exited {rc}")
    scheduler = settings.get("scheduler")
    if scheduler is not None:
        error = await _scx_switch(scheduler, cores)
        if error:
            errors.append(f"CPU scheduler {scheduler or 'kernel default'}: {error}")
    if errors:
        decky.logger.warning("handheld-control: %s", "; ".join(errors))
    return "; ".join(errors)

def _load_games():
    try:
        with open(GAMES_FILE) as f:
            data = json.load(f)
    except (OSError, ValueError):
        data = {}
    if not isinstance(data, dict):
        data = {}
    data.setdefault("default", {})
    data.setdefault("games", {})
    data.setdefault("applied", None)
    return data

def _save_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
    os.replace(tmp, path)

def _save_games(data):
    _save_json(GAMES_FILE, data)

async def _settings(*args, data=None):
    rc, out, err = await _exec(SETTINGS_CLI, *args, data=data)
    if rc == 0:
        return out, ""
    return None, err.strip().removeprefix("handheld-settings: ") or f"handheld-settings {args[0]} exited {rc}"

async def _settings_json(*args):
    out, error = await _settings(*args)
    if out is None:
        return None, error
    try:
        return json.loads(out), ""
    except json.JSONDecodeError as exc:
        return None, f"could not parse handheld-settings output: {exc}"

def _cli_error(err, rc, what):
    return err.strip().removeprefix("handheld-power: ") or f"handheld-power {what} exited {rc}"

async def _power_config():
    rc, out, err = await _run("config", "--json")
    if rc != 0:
        return None, _cli_error(err, rc, "config")
    try:
        return json.loads(out), None
    except json.JSONDecodeError as exc:
        return None, f"could not parse handheld-power config: {exc}"

def _load_dict(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError):
        data = {}
    return data if isinstance(data, dict) else {}

def _load_tuning():
    return _load_dict(TUNING_FILE)

def _load_caps():
    return _load_dict(FRAME_CAPS_FILE)

async def _shader(*args):
    # The user's own effects are under their home, which the CLI finds through HOME.
    rc, out, err = await _exec(SHADER_CLI, *args, env={**os.environ, "HOME": decky.DECKY_USER_HOME})
    if rc != 0:
        return None, err.strip().removeprefix("handheld-shader: ") or f"handheld-shader {args[0]} exited {rc}"
    return out, ""

def _steam_libraries():
    found = []
    for root in STEAM_ROOTS:
        base = os.path.join(decky.DECKY_USER_HOME, root)
        paths = [base]
        try:
            with open(os.path.join(base, "steamapps", "libraryfolders.vdf")) as f:
                paths += re.findall(r'"path"\s+"([^"]+)"', f.read())
        except OSError:
            pass
        for path in paths:
            real = os.path.realpath(path)
            if real not in found and os.path.isdir(os.path.join(real, "steamapps")):
                found.append(real)
    return found

def _fex_config(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError, TypeError):
        return None
    config = data.get("Config") if isinstance(data, dict) else None
    return config if isinstance(config, dict) else {}

def _proton_fex_global(compatdata):
    try:
        with open(os.path.join(compatdata, "config_info")) as f:
            lines = f.read().splitlines()
    except OSError:
        return None
    for line in lines[1:]:
        if "/files/" in line:
            dist = line[: line.index("/files/") + len("/files/")]
            return os.path.join(dist, "share", "fex-emu", "Config.json")
    return None

def _gamescope_session():
    found = []
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                argv = f.read().decode(errors="replace").split("\0")
            if os.path.basename(argv[0]) != "gamescope":
                continue
            with open(f"/proc/{pid}/stat") as f:
                started = int(f.read().rsplit(")", 1)[1].split()[19])
        except (OSError, ValueError, IndexError):
            continue
        found.append((started, pid, argv))
    return min(found) if found else None

def _refresh_arg(argv):
    args = argv[1:argv.index("--")] if "--" in argv else argv[1:]
    for i, arg in enumerate(args):
        if arg.startswith("--nested-refresh="):
            return arg.split("=", 1)[1]
        if arg in ("-r", "--nested-refresh") and i + 1 < len(args):
            return args[i + 1]
    return None

def _refresh_env(pid):
    try:
        with open(f"/proc/{pid}/environ", "rb") as f:
            entries = f.read().decode(errors="replace").split("\0")
    except OSError:
        return None
    for entry in entries:
        name, _, value = entry.partition("=")
        if name == REFRESH_ENV:
            return value
    return None

def _refresh_rate():
    session = _gamescope_session()
    if session is None:
        return None
    _, pid, argv = session
    for value in (_refresh_arg(argv), _refresh_env(pid)):
        try:
            rate = float(value)
        except (TypeError, ValueError):
            continue
        if rate > 0:
            return rate
    return None

class Plugin:

    def __init__(self):
        self._games_lock = asyncio.Lock()
        self._caps_lock = asyncio.Lock()
        self._game = None
        self._tuned = False
        self._tuning_lock = asyncio.Lock()
        self._shaded = False
        self._shader_lock = asyncio.Lock()

    async def _apply_tuning(self):
        async with self._tuning_lock:
            if not self._game:
                if self._tuned:
                    rc, _, err = await _run("game", "none")
                    self._tuned = rc != 0
                    return "" if rc == 0 else _cli_error(err, rc, "game none")
                return ""
            appid, cores = self._game
            tuning = _load_tuning().get(appid, {})
            args = []
            if tuning.get("nice"):
                args.append(f"nice={tuning['nice']}")
            if tuning.get("irq") and cores:
                args.append(f"irq={cores}")
            if not args and not self._tuned:
                return ""
            rc, _, err = await _run("game", appid, *args)
            if rc != 0:
                error = _cli_error(err, rc, "game")
                decky.logger.warning("handheld-control: game tuning: %s", error)
                return error
            self._tuned = True
            return ""

    # Takes off only an effect this put on, so one set some other way stays.
    async def _apply_shader(self):
        async with self._shader_lock:
            shader = _load_dict(SHADERS_FILE).get(self._game[0], "") if self._game else ""
            if not shader and not self._shaded:
                return ""
            _, error = await _shader(*(("set", shader) if shader else ("clear",)))
            if error:
                decky.logger.warning("handheld-control: shader: %s", error)
                return error
            self._shaded = bool(shader)
            return ""

    def _cores(self):
        return self._game[1] if self._game else None

    async def _scx_follow_game(self):
        props, _ = await _scx_props()
        if props is None or _scx_current(props) != SCX_DOMAIN_SCHEDULER:
            return
        error = await _scx_switch(SCX_DOMAIN_SCHEDULER, self._cores())
        if error:
            decky.logger.warning("handheld-control: %s domain: %s", SCX_DOMAIN_SCHEDULER, error)

    async def _main(self):
        decky.logger.info("handheld-control: backend started")

    async def _unload(self):
        decky.logger.info("handheld-control: backend stopped")

    async def _uninstall(self):
        pass

    async def get_status(self) -> dict:
        status, error = await _status()
        if status is None:
            decky.logger.warning("handheld-control: %s", error)
            return {"ok": False, "error": error}
        return {"ok": True, "status": status}

    async def get_options(self) -> dict:
        result: dict = {"ok": True, "profiles": [], "fanCurves": []}

        rc, out, _ = await _run("profile")
        if rc == 0:
            result["profiles"] = [ln[2:].strip() for ln in out.splitlines() if ln[2:].strip()]

        rc, out, _ = await _run("fan")
        if rc == 0:
            result["fanCurves"] = [ln[2:].strip() for ln in out.splitlines() if ln[2:].strip()]

        return result

    async def set_profile(self, name: str) -> dict:
        rc, _, err = await _run("profile", name)
        return {"ok": rc == 0, "error": err.strip()}

    async def set_fan_curve(self, name: str) -> dict:
        rc, _, err = await _run("fan", name)
        if rc == 0:
            await self._remember()
        return {"ok": rc == 0, "error": err.strip()}

    async def set_cpu(self, value: str) -> dict:
        rc, _, err = await _run("cpu", value)
        if rc == 0:
            await self._remember()
        return {"ok": rc == 0, "error": err.strip()}

    async def set_gpu(self, value: str) -> dict:
        rc, _, err = await _run("gpu", value)
        return {"ok": rc == 0, "error": err.strip()}

    async def reload_config(self) -> dict:
        rc, _, err = await _run("reload")
        return {"ok": rc == 0, "error": err.strip()}

    async def lsfg_status(self) -> dict:
        return await _lsfg("status")

    async def lsfg_get(self, appid: str) -> dict:
        return await _lsfg("get", str(appid))

    async def lsfg_enable(self, appid: str, name: str) -> dict:
        return await _lsfg("enable", str(appid), name)

    async def lsfg_claim(self, appid: str) -> dict:
        return await _lsfg("claim", str(appid))

    async def lsfg_disable(self, appid: str) -> dict:
        return await _lsfg("disable", str(appid))

    async def lsfg_set(self, appid: str, key: str, value) -> dict:
        return await _lsfg("set", str(appid), key, json.dumps(value))

    async def lsfg_set_global(self, key: str, value) -> dict:
        return await _lsfg("set-global", key, json.dumps(value))

    async def scx_status(self) -> dict:
        props, error = await _scx_props()
        if props is None:
            return {"ok": False, "available": await _scx_available(), "error": error}
        return {
            "ok": True,
            "available": True,
            "current": _scx_current(props),
            "mode": _scx_mode_name(props.get("SchedulerMode", 0)),
            "domain": _scx_domain(props.get("CurrentSchedulerArgs") or []),
            "schedulers": props.get("SupportedSchedulers", []),
        }

    async def settings_status(self) -> dict:
        status, error = await _settings_json("status", "--json")
        if status is None:
            return {"ok": False, "available": os.path.exists(SETTINGS_CLI), "error": error}
        return {"ok": True, "available": True, "status": status}

    async def settings_set(self, what: str, value) -> dict:
        if what == "usb":
            args = ("usb", "on" if value else "off")
        elif what == "ssh":
            args = ("ssh", "on" if value else "off")
        elif what == "stealth":
            args = ("stealth", "on" if value else "off")
        elif what == "stealth_boot":
            args = ("stealth-boot", "on" if value else "off")
        elif what == "controller":
            args = ("controller", str(value))
        elif what == "controller_poll":
            args = ("controller-poll", str(int(value)))
        else:
            return {"ok": False, "error": f"{what!r} is not a setting"}
        out, error = await _settings(*args)
        return {"ok": out is not None, "error": error}

    async def calibration_state(self) -> dict:
        state, error = await _settings_json("calibration", "--json")
        if state is None:
            return {"ok": False, "error": error}
        return {"ok": True, **state}

    async def calibration_session(self, on: bool) -> dict:
        out, error = await _settings("calibration", "start" if on else "stop")
        return {"ok": out is not None, "error": error}

    async def calibration_read(self) -> dict:
        data, _ = await _bus(SETTINGS_NAME, SETTINGS_PATH, "org.handheld.Settings1", "ReadControls")
        if data:
            try:
                return {"ok": True, **json.loads(data[0])}
            except (json.JSONDecodeError, TypeError):
                pass
        reply, error = await _settings_json("calibration", "read")
        if reply is None:
            return {"ok": False, "error": error}
        return {"ok": True, **reply}

    async def calibration_save(self, capture: dict) -> dict:
        out, error = await _settings("calibration", "save", data=json.dumps(capture).encode())
        return {"ok": out is not None, "error": error}

    async def calibration_reset(self) -> dict:
        out, error = await _settings("calibration", "reset")
        return {"ok": out is not None, "error": error}

    async def get_power_config(self) -> dict:
        config, error = await _power_config()
        if config is None:
            return {"ok": False, "error": error}
        return {"ok": True, "config": config}

    async def set_power_config(self, section: str, values: dict) -> dict:
        if not isinstance(values, dict) or not values:
            return {"ok": False, "error": "nothing to set"}
        pairs = [f"{key}={value}" for key, value in values.items()]
        rc, _, err = await _run("config", "set", str(section), *pairs)
        return {"ok": rc == 0, "error": "" if rc == 0 else _cli_error(err, rc, "config set")}

    async def reset_power_config(self, section: str) -> dict:
        rc, _, err = await _run("config", "reset", str(section) or "all")
        return {"ok": rc == 0, "error": "" if rc == 0 else _cli_error(err, rc, "config reset")}

    async def get_game_tuning(self, appid: str) -> dict:
        tuning = _load_tuning().get(str(appid), {})
        cores = self._cores() if self._game and self._game[0] == str(appid) else None
        return {
            "ok": True,
            "nice": int(tuning.get("nice", 0)),
            "irq": bool(tuning.get("irq", False)),
            "cores": cores or "",
        }

    async def set_game_tuning(self, appid: str, nice: int, irq: bool) -> dict:
        key = str(appid)
        if not key.isdigit():
            return {"ok": False, "error": f"{appid!r} is not a Steam app id"}
        if isinstance(nice, bool) or not isinstance(nice, int) or not GAME_NICE_RANGE[0] <= nice <= GAME_NICE_RANGE[1]:
            return {"ok": False, "error": f"{nice!r} is not a priority between -20 and 0"}
        async with self._games_lock:
            data = _load_tuning()
            if nice or irq:
                data[key] = {"nice": nice, "irq": bool(irq)}
            else:
                data.pop(key, None)
            _save_json(TUNING_FILE, data)
        error = await self._apply_tuning() if self._game and self._game[0] == key else ""
        return {"ok": not error, "error": error}

    async def get_game_shader(self, appid: str) -> dict:
        out, error = await _shader("list")
        if out is None:
            return {"ok": False, "available": os.access(SHADER_CLI, os.X_OK), "error": error}
        return {
            "ok": True,
            "available": True,
            "shaders": out.split(),
            "shader": _load_dict(SHADERS_FILE).get(str(appid), ""),
        }

    async def set_game_shader(self, appid: str, name: str) -> dict:
        key = str(appid)
        if not key.isdigit():
            return {"ok": False, "error": f"{appid!r} is not a Steam app id"}
        if name:
            out, error = await _shader("list")
            if out is None:
                return {"ok": False, "error": error}
            if name not in out.split():
                return {"ok": False, "error": f"{name!r} is not an installed effect"}
        async with self._games_lock:
            data = _load_dict(SHADERS_FILE)
            if name:
                data[key] = name
            else:
                data.pop(key, None)
            _save_json(SHADERS_FILE, data)
        error = await self._apply_shader() if self._game and self._game[0] == key else ""
        return {"ok": not error, "error": error}

    async def cpu_clusters(self) -> dict:
        return {
            "ok": True,
            "online": _format_cpulist(_online_cpus()),
            "clusters": [
                {"cpus": _format_cpulist(c["cpus"]), "count": len(c["cpus"]), "maxMhz": c["maxMhz"]}
                for c in _cpu_clusters()
            ],
        }

    async def turnip_drivers(self) -> dict:
        # turnip-perf comes with vulkan-freedreno, turnip-devel with vulkan-freedreno-devel.
        wrappers = ("turnip-perf", "turnip-devel")
        return {"ok": True, "installed": [w for w in wrappers if os.access(f"/usr/bin/{w}", os.X_OK)]}

    async def scx_set(self, name: str) -> dict:
        error = await _scx_switch(name, self._cores())
        if not error:
            await self._remember()
        return {"ok": not error, "error": error}

    async def fex_steam_config(self, appid: str) -> dict:
        if not str(appid).isdigit():
            return {"ok": False, "error": f"{appid!r} is not a Steam app id"}
        config, proton = None, {}
        for library in _steam_libraries():
            compatdata = os.path.join(library, "steamapps", "compatdata", str(appid))
            if not os.path.isdir(compatdata):
                continue
            config = _fex_config(os.path.join(compatdata, FEX_STEAM_CONFIG))
            proton = _fex_config(_proton_fex_global(compatdata)) or {}
            break
        defaults = {}
        for key, value in FEX_BUILTIN.items():
            source = "FEX"
            for layer, name in ((proton, "Proton"), (config or {}, "Steam")):
                if key in layer:
                    value, source = str(layer[key]), name
            if key == "SMCChecks":
                value = SMC_NAMES.get(value, value)
            defaults[key] = {"value": value, "source": source}
        return {"ok": True, "config": config, "defaults": defaults}

    async def frame_cap_get(self, appid: str) -> dict:
        cap = _load_caps().get(str(appid), 0)
        if isinstance(cap, bool) or not isinstance(cap, (int, float)):
            cap = 0
        return {"ok": True, "cap": cap, "refresh": _refresh_rate()}

    async def frame_cap_set(self, appid: str, cap) -> dict:
        if isinstance(cap, bool) or not isinstance(cap, (int, float)) or not 0 <= cap <= MAX_FRAME_CAP:
            return {"ok": False, "error": f"{cap!r} is not a frame cap between 0 and {MAX_FRAME_CAP}"}
        async with self._caps_lock:
            caps = _load_caps()
            if cap:
                caps[str(appid)] = cap
            else:
                caps.pop(str(appid), None)
            _save_json(FRAME_CAPS_FILE, caps)
        return {"ok": True}

    async def get_game(self, appid: str) -> dict:
        data = _load_games()
        return {"ok": True, "enabled": str(appid) in data["games"]}

    async def set_game_enabled(self, appid: str, name: str, enabled: bool) -> dict:
        key = str(appid)
        async with self._games_lock:
            data = _load_games()
            if enabled:
                captured, error = await _capture()
                if captured is None:
                    return {"ok": False, "error": error}
                if data["applied"] is None:
                    data["default"] = dict(captured)
                data["games"][key] = {"name": name, **captured}
                data["applied"] = key
                _save_games(data)
                decky.logger.info("handheld-control: per-game profile on for %s (%s)", name, key)
                return {"ok": True, "error": ""}

            data["games"].pop(key, None)
            error = ""
            if data["applied"] == key:
                error = await _apply(data["default"], self._cores())
                data["applied"] = None
            _save_games(data)
            decky.logger.info("handheld-control: per-game profile off for %s (%s)", name, key)
            return {"ok": not error, "error": error}

    async def game_started(self, appid: str, cores: str = "") -> dict:
        self._game = (str(appid), cores or None)
        result = await self._start_game(str(appid))
        await self._scx_follow_game()
        await self._apply_tuning()
        await self._apply_shader()
        return result

    async def game_stopped(self, appid: str) -> dict:
        if self._game and self._game[0] == str(appid):
            self._game = None
        result = await self._stop_game(str(appid))
        await self._scx_follow_game()
        await self._apply_tuning()
        await self._apply_shader()
        return result

    async def sync_running(self, appid: str, cores: str = "") -> dict:
        self._game = (str(appid), cores or None) if appid else None
        data = _load_games()
        if appid and str(appid) in data["games"]:
            result = {"ok": True, "error": ""}
            if data["applied"] != str(appid):
                result = await self._start_game(str(appid))
        elif data["applied"] is not None:
            result = await self._stop_game(data["applied"])
        else:
            result = {"ok": True, "error": ""}
        await self._scx_follow_game()
        if not self._game:
            self._tuned = True
        await self._apply_tuning()
        await self._apply_shader()
        return result

    async def _start_game(self, appid: str) -> dict:
        key = str(appid)
        async with self._games_lock:
            data = _load_games()
            game = data["games"].get(key)
            if game is None:
                return {"ok": True, "error": ""}
            if data["applied"] is None:
                captured, error = await _capture()
                if captured is None:
                    return {"ok": False, "error": error}
                data["default"] = captured
            error = await _apply(game, self._cores())
            data["applied"] = key
            _save_games(data)
            decky.logger.info("handheld-control: applied per-game profile for %s (%s)", game.get("name"), key)
            return {"ok": not error, "error": error}

    async def _stop_game(self, appid: str) -> dict:
        async with self._games_lock:
            data = _load_games()
            if data["applied"] != str(appid):
                return {"ok": True, "error": ""}
            error = await _apply(data["default"], self._cores())
            data["applied"] = None
            _save_games(data)
            decky.logger.info("handheld-control: restored defaults after %s", appid)
            return {"ok": not error, "error": error}

    async def _remember(self):
        async with self._games_lock:
            data = _load_games()
            captured, error = await _capture()
            if captured is None:
                decky.logger.warning("handheld-control: could not record settings: %s", error)
                return
            if data["applied"] is None:
                data["default"] = captured
            else:
                game = data["games"].get(data["applied"])
                if game is None:
                    data["applied"] = None
                    data["default"] = captured
                else:
                    game.update(captured)
            _save_games(data)
