#!/usr/bin/env python3
"""Profile logic of main.py, with decky stubbed and handheld-settings faked by a
script that keeps the MCU's two modes in a JSON file. Run: python3 test/test_main.py"""
import asyncio
import json
import os
import sys
import tempfile
import types

tmp = tempfile.mkdtemp()
decky = types.ModuleType("decky")
decky.DECKY_PLUGIN_SETTINGS_DIR = os.path.join(tmp, "settings")
decky.logger = types.SimpleNamespace(warning=lambda *a: None)
sys.modules["decky"] = decky
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import main  # noqa: E402

state = os.path.join(tmp, "mcu.json")
calls = os.path.join(tmp, "calls")
json.dump({"TouchAreaMode": "sticks", "DpadMode": "dpad"}, open(state, "w"))
cli = os.path.join(tmp, "handheld-settings")
with open(cli, "w") as f:
    f.write(f"""#!/usr/bin/env python3
import json, sys
s = json.load(open({state!r}))
if sys.argv[1] == "status":
    s["TouchAreaModes"] = [["sticks", "Sticks"], ["mouse", "Mouse"], ["off", "Off"], ["right-stick", "Right"]]
    s["DpadModes"] = [["dpad", "D-pad"], ["left-stick", "Left stick"]]
    print(json.dumps(s)); sys.exit()
open({calls!r}, "a").write(" ".join(sys.argv[1:]) + "\\n")
s[{{"touch-area": "TouchAreaMode", "dpad": "DpadMode"}}[sys.argv[1]]] = sys.argv[2]
json.dump(s, open({state!r}, "w"))
""")
os.chmod(cli, 0o755)
main.SETTINGS_CLI = cli

p = main.Plugin()
run = lambda coro: asyncio.run(coro)
mcu = lambda: tuple(json.load(open(state))[k] for k in ("TouchAreaMode", "DpadMode"))
writes = lambda: len(open(calls).readlines()) if os.path.exists(calls) else 0

r = run(p.get_modes(""))
assert r["ok"] and r["touch"]["current"] == "sticks" and r["per_game"] is False
assert main._load_profiles()["default"] == {"touch": "sticks", "dpad": "dpad"}, "first run saves today's modes"

run(p.set_mode("touch", "off"))
assert mcu() == ("off", "dpad") and main._load_profiles()["default"]["touch"] == "off"

run(p.game_started("123"))
assert mcu() == ("off", "dpad"), "a game with no profile keeps the default"
n = writes()
run(p.game_started("123"))
assert writes() == n, "modes already in force are not rewritten"

run(p.set_per_game("123", True))
assert run(p.get_modes("123"))["per_game"] is True
run(p.set_mode("dpad", "left-stick"))
run(p.set_mode("touch", "mouse"))
assert mcu() == ("mouse", "left-stick")
assert main._load_profiles()["default"] == {"touch": "off", "dpad": "dpad"}, "game edits leave the default"

run(p.game_stopped("123"))
assert mcu() == ("off", "dpad"), "exit restores the default"
run(p.game_started("123"))
assert mcu() == ("mouse", "left-stick"), "start applies the game's profile"
run(p.game_stopped("999"))
assert mcu() == ("mouse", "left-stick"), "another game's exit changes nothing"

run(p.game_started("456"))
assert mcu() == ("off", "dpad"), "a game without a profile gets the default"
run(p.set_per_game("123", False))
assert mcu() == ("off", "dpad") and "123" not in main._load_profiles()["games"]

run(p.set_per_game("456", True))
assert mcu() == ("off", "dpad"), "a new profile starts as the default"
run(p.set_per_game("456", False))
run(p.set_mode("touch", "right-stick"))
assert main._load_profiles()["default"]["touch"] == "right-stick", "without a profile, edits go to the default"
print("ok")
