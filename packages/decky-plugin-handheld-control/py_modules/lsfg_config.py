import json
import os
import shutil
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

MANIFEST = "VkLayer_LSFGVK_frame_generation.json"
MANIFEST_DIRS = (
    "/usr/share/vulkan/implicit_layer.d",
    "/etc/vulkan/implicit_layer.d",
    "~/.local/share/vulkan/implicit_layer.d",
)
STEAM_LIBRARIES = (
    ".local/share/Steam/steamapps/common",
    ".steam/steam/steamapps/common",
    ".steam/debian-installation/steamapps/common",
    ".var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/common",
    "snap/steam/common/.local/share/Steam/steamapps/common",
)

NEW_PROFILE = {
    "multiplier": 2,
    "flow_scale": 0.8,
    "performance_mode": True,
    "pacing_mode": "vsync",
    "override_present_mode": True,
    "color_space": "srgb",
    "transfer_function": "srgb",
    "preserve_swapchain_image_count": False,
}
PROFILE_FIELDS = {
    "multiplier": ("int", 1, 20),
    "flow_scale": ("float", 0.25, 1.0),
    "performance_mode": ("bool",),
    "override_present_mode": ("bool",),
    "preserve_swapchain_image_count": ("bool",),
    "color_space": ("enum", "srgb", "hdr10", "scrgb", "dcip3"),
    "transfer_function": ("enum", "srgb", "linear", "pq", "hlg", "scrgbnl", "dcip3"),
}
GLOBAL_FIELDS = {
    "allow_fp16": ("bool",),
}


class ConfigError(Exception):
    pass


def config_path():
    xdg = os.environ.get("XDG_CONFIG_HOME")
    if xdg and not os.environ.get("LSFGVK_FLATPAK"):
        return Path(xdg) / "lsfg-vk" / "conf.toml"
    return Path.home() / ".config" / "lsfg-vk" / "conf.toml"


def installed():
    return any(
        os.path.exists(os.path.join(os.path.expanduser(d), MANIFEST)) for d in MANIFEST_DIRS
    )


def find_dll(data):
    configured = data.get("global", {}).get("dll") or os.environ.get("LSFGVK_DLL_PATH")
    if configured:
        return configured if os.path.exists(configured) else None
    prefixes = [os.environ.get("XDG_DATA_HOME"), str(Path.home())]
    for prefix in filter(None, prefixes):
        for library in STEAM_LIBRARIES:
            candidate = os.path.join(prefix, library, "Lossless Scaling", "lsfg-vk.dll")
            if os.path.exists(candidate):
                return candidate
    return None


def load(path):
    if not path.exists():
        return {"version": 2, "global": {"allow_fp16": True, "log_level": "info"}, "profile": []}
    try:
        with open(path, "rb") as f:
            data = tomllib.load(f)
    except tomllib.TOMLDecodeError as exc:
        raise ConfigError(f"{path} is not valid TOML: {exc}")
    if data.get("version") != 2:
        raise ConfigError(f"{path} is not an lsfg-vk 2.x configuration (version must be 2)")
    profiles = data.get("profile", [])
    data["profile"] = [profiles] if isinstance(profiles, dict) else list(profiles)
    data.setdefault("global", {})
    return data


def owns(profile, appid):
    active = profile.get("active_in")
    return active == appid or active == [appid]


def find(data, appid):
    for profile in data["profile"]:
        if owns(profile, appid):
            return profile
    return None


def game_identities(appid):
    marker = f"SteamAppId={appid}".encode()
    paths, names = set(), set()
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            with open(f"/proc/{pid}/environ", "rb") as f:
                if marker not in f.read().split(b"\0"):
                    continue
        except OSError:
            continue
        try:
            paths.add(os.readlink(f"/proc/{pid}/exe"))
            with open(f"/proc/{pid}/comm") as f:
                names.add(f.read().strip())
            with open(f"/proc/{pid}/maps") as f:
                for line in f:
                    line = line.rstrip("\n")
                    if line.endswith(".exe"):
                        start = line.find("/")
                        paths.add(line[start:] if start >= 0 else line)
        except OSError:
            continue
    return paths, names


def active_entries(profile):
    active = profile.get("active_in", [])
    return [active] if isinstance(active, str) else list(active)


def shadowing(data, appid):
    paths, names = game_identities(appid)
    found = []
    for profile in data["profile"]:
        if owns(profile, appid):
            continue
        hits = [
            entry for entry in active_entries(profile)
            if entry and (entry == appid or entry in names or any(p.endswith(entry) for p in paths))
        ]
        if hits:
            found.append({"profile": profile.get("name", ""), "entries": hits})
    return found


def fmt(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return repr(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, list):
        return "[ " + ", ".join(fmt(v) for v in value) + " ]" if value else "[]"
    raise ConfigError(f"cannot write value of type {type(value).__name__}")


def dump(data):
    lines, tables = [], []
    for key, value in data.items():
        if isinstance(value, dict):
            tables.append((key, [value], False))
        elif isinstance(value, list) and value and all(isinstance(v, dict) for v in value):
            tables.append((key, value, True))
        else:
            lines.append(f"{key} = {fmt(value)}")
    for key, items, is_array in tables:
        for item in items:
            lines.append("")
            lines.append(f"[[{key}]]" if is_array else f"[{key}]")
            lines.extend(f"{k} = {fmt(v)}" for k, v in item.items())
    return "\n".join(lines) + "\n"


def save(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".conf.toml.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(dump(data))
        check = subprocess.run(
            ["lsfg-vk-cli", "validate", "-c", tmp], capture_output=True, text=True, timeout=10
        )
        if check.returncode != 0:
            lines = (check.stderr or check.stdout).strip().splitlines()
            raise ConfigError(f"lsfg-vk rejected the change: {lines[-1] if lines else 'unknown error'}")
        if path.exists():
            shutil.copy2(path, path.with_name(path.name + ".bak"))
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def coerce(spec, raw):
    kind = spec[0]
    if kind == "bool":
        if not isinstance(raw, bool):
            raise ConfigError(f"expected true or false, got {raw!r}")
        return raw
    if kind == "int":
        value = int(raw)
        if not spec[1] <= value <= spec[2]:
            raise ConfigError(f"{value} is outside {spec[1]}-{spec[2]}")
        return value
    if kind == "float":
        value = round(float(raw), 2)
        if not spec[1] <= value <= spec[2]:
            raise ConfigError(f"{value} is outside {spec[1]}-{spec[2]}")
        return value
    if raw not in spec[1:]:
        raise ConfigError(f"{raw!r} is not one of {', '.join(spec[1:])}")
    return raw


def check_appid(appid):
    if not appid.isdigit() or appid == "0":
        raise ConfigError(f"{appid!r} is not a Steam app id")
    return appid


def cmd_status(args):
    path = config_path()
    result = {"installed": installed(), "configPath": str(path), "configError": "", "dll": None, "allowFp16": True}
    try:
        data = load(path)
        result["dll"] = find_dll(data)
        result["allowFp16"] = data["global"].get("allow_fp16", True)
    except ConfigError as exc:
        result["configError"] = str(exc)
    return result


def cmd_get(args):
    appid = check_appid(args[0])
    data = load(config_path())
    return {"profile": find(data, appid), "shadowedBy": shadowing(data, appid)}


def cmd_claim(args):
    appid = check_appid(args[0])
    path = config_path()
    data = load(path)
    shadows = {s["profile"]: set(s["entries"]) for s in shadowing(data, appid)}
    for profile in data["profile"]:
        drop = shadows.get(profile.get("name", ""))
        if drop and not owns(profile, appid):
            profile["active_in"] = [e for e in active_entries(profile) if e not in drop]
    if shadows:
        save(path, data)
    return {"profile": find(data, appid), "shadowedBy": shadowing(data, appid)}


def cmd_enable(args):
    appid, name = check_appid(args[0]), args[1] or args[0]
    path = config_path()
    data = load(path)
    profile = find(data, appid)
    if profile is None:
        profile = {"name": f"{name} ({appid})", "active_in": [appid], **NEW_PROFILE}
        data["profile"].append(profile)
        save(path, data)
    return {"profile": profile}


def cmd_disable(args):
    appid = check_appid(args[0])
    path = config_path()
    data = load(path)
    kept = [p for p in data["profile"] if not owns(p, appid)]
    if len(kept) != len(data["profile"]):
        data["profile"] = kept
        save(path, data)
    return {"profile": None}


def cmd_set(args):
    appid, key, raw = check_appid(args[0]), args[1], json.loads(args[2])
    if key not in PROFILE_FIELDS:
        raise ConfigError(f"{key!r} is not a profile setting")
    path = config_path()
    data = load(path)
    profile = find(data, appid)
    if profile is None:
        raise ConfigError("frame generation is not enabled for this game")
    profile[key] = coerce(PROFILE_FIELDS[key], raw)
    save(path, data)
    return {"profile": profile}


def cmd_set_global(args):
    key, raw = args[0], json.loads(args[1])
    if key not in GLOBAL_FIELDS:
        raise ConfigError(f"{key!r} is not a global setting")
    path = config_path()
    data = load(path)
    data["global"][key] = coerce(GLOBAL_FIELDS[key], raw)
    save(path, data)
    return {}


COMMANDS = {
    "status": (cmd_status, 0),
    "get": (cmd_get, 1),
    "claim": (cmd_claim, 1),
    "enable": (cmd_enable, 2),
    "disable": (cmd_disable, 1),
    "set": (cmd_set, 3),
    "set-global": (cmd_set_global, 2),
}


def main(argv):
    if not argv or argv[0] not in COMMANDS or len(argv) - 1 != COMMANDS[argv[0]][1]:
        print(json.dumps({"ok": False, "error": f"usage: lsfg_config.py {'|'.join(COMMANDS)} ..."}))
        return 2
    handler = COMMANDS[argv[0]][0]
    try:
        result = handler(argv[1:])
    except (ConfigError, ValueError, OSError, subprocess.SubprocessError) as exc:
        print(json.dumps({"ok": False, "error": str(exc)}))
        return 1
    print(json.dumps({"ok": True, **result}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
