import { Router } from "@decky/ui";

export interface Tweak { key: string; label: string; env: [string, string][]; excludes?: string }

export const TWEAKS: Tweak[] = [
  { key: "wow64", label: "WOW64 for 32-bit games", env: [["PROTON_USE_WOW64", "1"]] },
  { key: "noSteamDeck", label: "Disable Steam Deck mode", env: [["SteamDeck", "0"]] },
  { key: "mangohud", label: "MangoHud workaround", env: [["MANGOHUD", "1"]] },
  { key: "noVkbasalt", label: "Disable vkBasalt", env: [["DISABLE_VKBASALT", "1"]], excludes: "vkbasalt" },
  { key: "vkbasalt", label: "Force enable vkBasalt", env: [["ENABLE_VKBASALT", "1"]], excludes: "noVkbasalt" },
  { key: "noWsi", label: "Disable gamescope WSI", env: [["ENABLE_GAMESCOPE_WSI", "0"], ["DXVK_HDR", "0"]] },
  { key: "safePreempt", label: "Turnip safe preemption", env: [["TU_SAFE_PREEMPT", "1"]] },
  {
    key: "zink",
    label: "Zink for OpenGL games",
    env: [
      ["__GLX_VENDOR_LIBRARY_NAME", "mesa"],
      ["MESA_LOADER_DRIVER_OVERRIDE", "zink"],
      ["GALLIUM_DRIVER", "zink"],
    ],
  },
];
// Not noWsi: through XWayland, lsfg-vk's 2x output topped out at 80 fps on a
// 120 Hz panel (two refreshes out of three); with gamescope WSI it reaches 120.
export const FRAMEGEN_TWEAKS = ["safePreempt"];

export interface FexPreset { key: string; label: string; description: string; env: [string, string][] }

const FEX_FLAGS = [
  "FEX_TSOENABLED",
  "FEX_VECTORTSOENABLED",
  "FEX_MEMCPYSETTSOENABLED",
  "FEX_HALFBARRIERTSOENABLED",
  "FEX_X87REDUCEDPRECISION",
  "FEX_MULTIBLOCK",
];

const fexEnv = (...values: number[]): [string, string][] =>
  FEX_FLAGS.map((name, i) => [name, String(values[i])]);

export const FEX_PRESETS: FexPreset[] = [
  {
    key: "fast",
    label: "Fast",
    description: "No memory-order (TSO) emulation, reduced-precision x87",
    env: fexEnv(0, 0, 0, 0, 1, 1),
  },
  {
    key: "balanced",
    label: "Balanced",
    description: "TSO with half barriers, reduced-precision x87",
    env: fexEnv(1, 0, 0, 1, 1, 1),
  },
  {
    key: "compatible",
    label: "Compatible",
    description: "Full TSO, precise x87, no multiblock: slowest",
    env: fexEnv(1, 1, 1, 1, 0, 0),
  },
];
export const FEX_STEAM = "";
export const FEX_CUSTOM = "custom";

export interface FexOption {
  env: string;
  key: string;
  label: string;
  description: string;
  choices: [string, string][];
  tso?: boolean;
}

const ON_OFF: [string, string][] = [
  ["1", "On"],
  ["0", "Off"],
];

export const FEX_OPTIONS: FexOption[] = [
  {
    env: "FEX_TSOENABLED",
    key: "TSOEnabled",
    label: "TSO emulation",
    description: "x86 memory ordering. Off is much faster and can crash multithreaded games.",
    choices: ON_OFF,
  },
  {
    env: "FEX_VECTORTSOENABLED",
    key: "VectorTSOEnabled",
    label: "Vector TSO",
    description: "Vector loads and stores are ordered too",
    choices: ON_OFF,
    tso: true,
  },
  {
    env: "FEX_MEMCPYSETTSOENABLED",
    key: "MemcpySetTSOEnabled",
    label: "memcpy/memset TSO",
    description: "REP MOVS and REP STOS are ordered too",
    choices: ON_OFF,
    tso: true,
  },
  {
    env: "FEX_HALFBARRIERTSOENABLED",
    key: "HalfBarrierTSOEnabled",
    label: "Half-barrier TSO",
    description: "Unaligned accesses fall back to half barriers instead of full ones",
    choices: ON_OFF,
    tso: true,
  },
  {
    env: "FEX_X87REDUCEDPRECISION",
    key: "X87ReducedPrecision",
    label: "x87 reduced precision",
    description: "64-bit x87 maths instead of 80-bit. Faster, may cause rendering errors.",
    choices: ON_OFF,
  },
  {
    env: "FEX_MULTIBLOCK",
    key: "Multiblock",
    label: "Multiblock",
    description: "Compile across block boundaries: faster code, longer compiles",
    choices: ON_OFF,
  },
  {
    env: "FEX_VOLATILEMETADATA",
    key: "VolatileMetadata",
    label: "Use volatile metadata",
    description: "Apply TSO only where the executable marks it as needed",
    choices: ON_OFF,
  },
  {
    env: "FEX_SMCCHECKS",
    key: "SMCChecks",
    label: "Self-modifying code checks",
    description: "None is faster but breaks games or DRM that patch their own code",
    choices: [
      ["none", "None"],
      ["mtrack", "Page tracking"],
      ["full", "Full (slow)"],
    ],
  },
  {
    env: "FEX_STRICTINPROCESSSPLITLOCKS",
    key: "StrictInProcessSplitLocks",
    label: "Strict split locks",
    description: "Correct atomics across cache lines. Slow, fixes some games.",
    choices: ON_OFF,
  },
  {
    env: "FEX_MAXINST",
    key: "MaxInst",
    label: "Block size",
    description: "Instructions per compiled block. Smaller compiles faster, larger runs faster.",
    choices: ["250", "500", "1000", "2000", "5000"].map((n): [string, string] => [n, n]),
  },
  {
    env: "FEX_MONOHACKS",
    key: "MonoHacks",
    label: "Mono hacks",
    description: "Special handling for Unity and Mono games",
    choices: ON_OFF,
  },
  {
    env: "FEX_HIDEHYPERVISORBIT",
    key: "HideHypervisorBit",
    label: "Hide hypervisor bit",
    description: "For games that refuse to run in a virtual machine",
    choices: ON_OFF,
  },
];
const FEX_EXTRAS = FEX_OPTIONS.map((o) => o.env).filter((env) => !FEX_FLAGS.includes(env));

// DXVK dropped DXVK_FRAME_RATE (dae35be7e, 2025-11): its cap is a config option
// now, set through DXVK_CONFIG. One option per API, because the unified
// dxvk.maxFrameRate (3db36db2e, 2026-06-09) is newer than the DXVK in Proton 11
// (a6764047e), which ignores it. The `;` between them needs the quotes. The older
// forms are still read, so their launch options are rewritten on the next launch.
const LEGACY_DXVK_CAP = "DXVK_FRAME_RATE";
const VKD3D_CAP = "VKD3D_FRAME_RATE";
const DXVK_CONFIG = "DXVK_CONFIG";
const DXVK_CAP = /^"?(?:dxvk\.maxFrameRate=(\d+)|dxgi\.maxFrameRate=(\d+);d3d9\.maxFrameRate=\2)"?$/;
const dxvkCapConfig = (fps: number) => `"dxgi.maxFrameRate=${fps};d3d9.maxFrameRate=${fps}"`;
const MANAGED_VARS = new Set([
  LEGACY_DXVK_CAP,
  VKD3D_CAP,
  ...TWEAKS.flatMap((t) => t.env.map(([name]) => name)),
  ...FEX_OPTIONS.map((o) => o.env),
]);
const COMMAND = "%command%";
const TASKSET = "taskset";
const CPU_LIST_FLAGS = ["-c", "--cpu-list"];
const CPU_LIST = /^\d+(-\d+)?(,\d+(-\d+)?)*$/;
const ASSIGNMENT = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/;
const DETAILS_TIMEOUT_MS = 2000;

export interface LaunchTweaks {
  flags: Record<string, boolean>;
  frameCap: number;
  fex: string;
  fexFlags: Record<string, string>;
  cores: string;
}
export interface Game { appid: string; name: string }

const tokenize = (text: string): string[] => {
  const tokens: string[] = [];
  let current = "";
  let quote: string | null = null;
  let started = false;
  for (const ch of text) {
    if (quote) {
      current += ch;
      if (ch === quote) quote = null;
    } else if (ch === '"' || ch === "'") {
      current += ch;
      quote = ch;
      started = true;
    } else if (/\s/.test(ch)) {
      if (started) tokens.push(current);
      current = "";
      started = false;
    } else {
      current += ch;
      started = true;
    }
  }
  if (started) tokens.push(current);
  return tokens;
};

const splitLaunchOptions = (options: string) => {
  const at = options.indexOf(COMMAND);
  const prefix = at < 0 ? "" : options.slice(0, at);
  const suffix = (at < 0 ? options : options.slice(at + COMMAND.length)).trim();
  const tokens = tokenize(prefix);
  let cores = "";
  const pin = tokens.findIndex(
    (token, i) => token === TASKSET && CPU_LIST_FLAGS.includes(tokens[i + 1]) && CPU_LIST.test(tokens[i + 2] ?? ""),
  );
  if (pin >= 0) cores = tokens.splice(pin, 3)[2];
  const managed = new Map<string, string>();
  const other: string[] = [];
  for (const token of tokens) {
    const match = ASSIGNMENT.exec(token);
    // A DXVK_CONFIG is ours only when it holds nothing but the cap.
    const ours = match && (MANAGED_VARS.has(match[1]) || (match[1] === DXVK_CONFIG && DXVK_CAP.test(match[2])));
    if (ours) managed.set(match[1], match[2]);
    else other.push(token);
  }
  return { managed, other, cores, suffix, hasCommand: at >= 0 };
};

const readFex = (managed: Map<string, string>): string => {
  if (!FEX_FLAGS.some((name) => managed.has(name))) return FEX_STEAM;
  const preset = FEX_PRESETS.find((p) => p.env.every(([name, value]) => managed.get(name) === value));
  return preset ? preset.key : FEX_CUSTOM;
};

export const readTweaks = (options: string): LaunchTweaks => {
  const { managed, cores } = splitLaunchOptions(options);
  const flags: Record<string, boolean> = {};
  for (const tweak of TWEAKS) {
    flags[tweak.key] = tweak.env.every(([name, value]) => managed.get(name) === value);
  }
  const dxvk = DXVK_CAP.exec(managed.get(DXVK_CONFIG) ?? "");
  const cap = [managed.get(VKD3D_CAP), dxvk?.[1] ?? dxvk?.[2], managed.get(LEGACY_DXVK_CAP)]
    .map(Number)
    .find((fps) => fps > 0);
  const fexFlags: Record<string, string> = {};
  for (const option of FEX_OPTIONS) {
    const value = managed.get(option.env);
    if (value !== undefined) fexFlags[option.env] = value;
  }
  return { flags, frameCap: cap ?? 0, fex: readFex(managed), fexFlags, cores };
};

// The cap is there, but in a form that Proton 11's DXVK ignores.
export const hasStaleFrameCap = (options: string) => {
  const { managed } = splitLaunchOptions(options);
  const dxvk = managed.get(DXVK_CONFIG);
  return managed.has(LEGACY_DXVK_CAP) || (dxvk !== undefined && !DXVK_CAP.exec(dxvk)?.[2]);
};

export const fpsText = (fps: number) => String(Math.round(fps * 100) / 100);

export const writeTweaks = (options: string, tweaks: LaunchTweaks): string => {
  const { other, suffix, hasCommand } = splitLaunchOptions(options);
  const assignments: string[] = [];
  if (tweaks.frameCap > 0) {
    // DXVK parses an integer; rounding down keeps the base rate under the cap. A
    // DXVK_CONFIG of the user's own is left alone, and with it DXVK's cap: a second
    // assignment would silently replace one of them.
    if (!other.some((token) => token.startsWith(`${DXVK_CONFIG}=`))) {
      assignments.push(`${DXVK_CONFIG}=${dxvkCapConfig(Math.floor(tweaks.frameCap))}`);
    }
    assignments.push(`${VKD3D_CAP}=${fpsText(tweaks.frameCap)}`);
  }
  for (const tweak of TWEAKS) {
    if (!tweaks.flags[tweak.key]) continue;
    for (const [name, value] of tweak.env) assignments.push(`${name}=${value}`);
  }
  if (tweaks.fex === FEX_CUSTOM) {
    for (const name of FEX_FLAGS) {
      if (tweaks.fexFlags[name] !== undefined) assignments.push(`${name}=${tweaks.fexFlags[name]}`);
    }
  } else {
    const preset = FEX_PRESETS.find((p) => p.key === tweaks.fex);
    for (const [name, value] of preset?.env ?? []) assignments.push(`${name}=${value}`);
  }
  for (const name of FEX_EXTRAS) {
    if (tweaks.fexFlags[name] !== undefined) assignments.push(`${name}=${tweaks.fexFlags[name]}`);
  }
  const lead = other.findIndex((token) => !ASSIGNMENT.test(token));
  const split = lead < 0 ? other.length : lead;
  const pin = tweaks.cores ? [TASKSET, "-c", tweaks.cores] : [];
  const prefix = [...assignments, ...other.slice(0, split), ...pin, ...other.slice(split)];
  if (prefix.length === 0) return hasCommand && suffix ? `${COMMAND} ${suffix}` : suffix;
  return [...prefix, COMMAND, suffix].filter(Boolean).join(" ");
};

export const launchOptionsOf = (appid: number) =>
  new Promise<string | null>((resolve) => {
    const known = window.appDetailsStore?.GetAppDetails(appid);
    if (known) {
      resolve(known.strLaunchOptions ?? "");
      return;
    }
    let done = false;
    let details: { unregister: () => void } | null = null;
    const finish = (options: string | null) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      details?.unregister();
      resolve(options);
    };
    const timer = setTimeout(() => finish(null), DETAILS_TIMEOUT_MS);
    details = SteamClient.Apps.RegisterForAppDetails(appid, (d) => finish(d.strLaunchOptions ?? ""));
    if (done) details.unregister();
  });

export const runningGame = (): Game | null => {
  const app = Router.MainRunningApp;
  return app ? { appid: String(app.appid), name: app.display_name } : null;
};
