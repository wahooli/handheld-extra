import { DropdownItem, PanelSectionRow, ToggleField } from "@decky/ui";
import { callable } from "@decky/api";
import { useEffect, useState } from "react";
import {
  FEX_CUSTOM,
  FEX_OPTIONS,
  FEX_PRESETS,
  FEX_STEAM,
  FexOption,
  Game,
  LaunchTweaks,
  readTweaks,
  writeTweaks,
} from "./launchOptions";

type FexConfig = Record<string, string>;
type FexDefaults = Record<string, { value: string; source: string }>;
interface FexSteamReply { ok: boolean; error?: string; config?: FexConfig | null; defaults?: FexDefaults }
interface Cluster { cpus: string; count: number; maxMhz: number }
interface ClustersReply { ok: boolean; online: string; clusters: Cluster[] }
interface CorePreset { data: string; label: string }

const fexSteamConfig = callable<[appid: string], FexSteamReply>("fex_steam_config");
const cpuClusters = callable<[], ClustersReply>("cpu_clusters");

const ALL_CORES = "";
const FLAG_DEFAULT = "";

let advancedOpen = false;

const choiceLabel = (option: FexOption, value: string) =>
  option.choices.find(([v]) => v === value)?.[1] ?? value;

const parseCpus = (list: string): number[] =>
  list.split(",").flatMap((part) => {
    const [low, high = low] = part.split("-").map(Number);
    return Array.from({ length: Math.max(0, high - low + 1) }, (_, i) => low + i);
  });

const formatCpus = (cpus: number[]): string => {
  const runs: [number, number][] = [];
  for (const cpu of [...new Set(cpus)].sort((a, b) => a - b)) {
    const last = runs[runs.length - 1];
    if (last && cpu === last[1] + 1) last[1] = cpu;
    else runs.push([cpu, cpu]);
  }
  return runs.map(([a, b]) => (b > a ? `${a}-${b}` : String(a))).join(",");
};

const corePresets = (clusters: Cluster[]): CorePreset[] => {
  const mixed = new Set(clusters.map((c) => c.maxMhz)).size > 1;
  const presets: CorePreset[] = [];
  for (let first = 0; first < clusters.length; first++) {
    for (let last = first; last < clusters.length; last++) {
      if (first === 0 && last === clusters.length - 1) continue;
      const run = clusters.slice(first, last + 1);
      const cpus = formatCpus(run.flatMap((c) => parseCpus(c.cpus)));
      const count = run.reduce((sum, c) => sum + c.count, 0);
      const mhz = mixed && run.length === 1 ? `, ${run[0].maxMhz} MHz` : "";
      presets.push({ data: cpus, label: `Cores ${cpus} (${count}${mhz})` });
    }
  }
  const size = (p: CorePreset) => parseCpus(p.data);
  return presets.sort((a, b) => size(a).length - size(b).length || size(a)[0] - size(b)[0]);
};

const onOff = (value: string) => (value === "0" ? "off" : "on");

const steamDescription = (config: FexConfig | null | undefined) => {
  if (config === undefined) return "Proton's per-game FEX settings from Steam";
  if (config === null) return "Proton's per-game FEX settings from Steam, shown after the first launch";
  const parts = [
    config.TSOEnabled !== undefined ? `TSO ${onOff(config.TSOEnabled)}` : null,
    config.Multiblock !== undefined ? `multiblock ${onOff(config.Multiblock)}` : null,
  ].filter(Boolean);
  return parts.length ? `Steam sets ${parts.join(", ")} for this game` : "Steam sets nothing for this game";
};

export function GameLaunchSettings({ game }: { game: Game }) {
  const [launchOptions, setLaunchOptions] = useState<string | null>(null);
  const [steamConfig, setSteamConfig] = useState<FexConfig | null | undefined>(undefined);
  const [fexDefaults, setFexDefaults] = useState<FexDefaults>({});
  const [advanced, setAdvanced] = useState(advancedOpen);
  const [clusters, setClusters] = useState<Cluster[]>([]);

  useEffect(() => {
    let live = true;
    void cpuClusters().then((reply) => {
      if (live && reply.ok) setClusters(reply.clusters);
    });
    return () => {
      live = false;
    };
  }, []);

  useEffect(() => {
    setLaunchOptions(null);
    setSteamConfig(undefined);
    let live = true;
    void fexSteamConfig(game.appid).then((reply) => {
      if (!live) return;
      setSteamConfig(reply.ok ? reply.config ?? null : null);
      setFexDefaults(reply.ok ? reply.defaults ?? {} : {});
    });
    const appid = Number(game.appid);
    const known = window.appDetailsStore?.GetAppDetails(appid);
    if (known) setLaunchOptions(known.strLaunchOptions ?? "");
    const details = SteamClient.Apps.RegisterForAppDetails(appid, (d) => {
      if (live) setLaunchOptions(d.strLaunchOptions ?? "");
    });
    return () => {
      live = false;
      details.unregister();
    };
  }, [game.appid]);

  const tweaks = readTweaks(launchOptions ?? "");

  const setTweaks = (next: LaunchTweaks) => {
    if (launchOptions === null) return;
    const options = writeTweaks(launchOptions, next);
    SteamClient.Apps.SetAppLaunchOptions(Number(game.appid), options);
    setLaunchOptions(options);
  };

  const options = [
    { data: FEX_STEAM, label: "Steam default" },
    ...FEX_PRESETS.map((p) => ({ data: p.key, label: p.label })),
    ...(tweaks.fex === FEX_CUSTOM ? [{ data: FEX_CUSTOM, label: "Custom" }] : []),
  ];
  const description =
    tweaks.fex === FEX_STEAM
      ? steamDescription(steamConfig)
      : tweaks.fex === FEX_CUSTOM
        ? "Custom flags, see Advanced FEX flags"
        : FEX_PRESETS.find((p) => p.key === tweaks.fex)?.description;

  const setFlag = (option: FexOption, value: string) => {
    const fexFlags = { ...tweaks.fexFlags };
    if (value === FLAG_DEFAULT) delete fexFlags[option.env];
    else fexFlags[option.env] = value;
    setTweaks({ ...tweaks, fex: FEX_CUSTOM, fexFlags });
  };
  const tsoOn = (tweaks.fexFlags.FEX_TSOENABLED ?? fexDefaults.TSOEnabled?.value ?? "1") !== "0";

  const presets = corePresets(clusters);
  const cores = presets.find((p) => tweaks.cores && p.data === formatCpus(parseCpus(tweaks.cores)))?.data ?? tweaks.cores;
  const coreOptions = [
    { data: ALL_CORES, label: "All cores" },
    ...presets,
    ...(cores && !presets.some((p) => p.data === cores) ? [{ data: cores, label: `Custom (${cores})` }] : []),
  ];
  const coreDescription = tweaks.cores
    ? "Pinned to these cores. Under scx_cosmos, other work is kept off them."
    : "The game can run on any core";

  return (
    <>
      <PanelSectionRow>
        <DropdownItem
          label="FEX preset"
          description={description}
          rgOptions={options}
          selectedOption={tweaks.fex}
          disabled={launchOptions === null}
          onChange={(opt) => setTweaks({ ...tweaks, fex: opt.data as string })}
        />
      </PanelSectionRow>
      <PanelSectionRow>
        <ToggleField
          label="Advanced FEX flags"
          description={
            Object.keys(tweaks.fexFlags).length
              ? `${Object.keys(tweaks.fexFlags).length} set in the launch options`
              : "All at their defaults"
          }
          checked={advanced}
          onChange={(on) => {
            advancedOpen = on;
            setAdvanced(on);
          }}
        />
      </PanelSectionRow>
      {advanced &&
        FEX_OPTIONS.map((option) => {
          const fallback = fexDefaults[option.key];
          return (
            <PanelSectionRow key={option.env}>
              <DropdownItem
                label={option.label}
                description={option.tso && !tsoOn ? `${option.description}. Only matters while TSO is on.` : option.description}
                rgOptions={[
                  {
                    data: FLAG_DEFAULT,
                    label: fallback ? `Default (${choiceLabel(option, fallback.value)}, ${fallback.source})` : "Default",
                  },
                  ...option.choices.map(([data, label]) => ({ data, label })),
                ]}
                selectedOption={tweaks.fexFlags[option.env] ?? FLAG_DEFAULT}
                disabled={launchOptions === null}
                onChange={(opt) => setFlag(option, opt.data as string)}
              />
            </PanelSectionRow>
          );
        })}
      {clusters.length > 1 && (
        <PanelSectionRow>
          <DropdownItem
            label="CPU cores"
            description={coreDescription}
            rgOptions={coreOptions}
            selectedOption={cores}
            disabled={launchOptions === null}
            onChange={(opt) => setTweaks({ ...tweaks, cores: opt.data as string })}
          />
        </PanelSectionRow>
      )}
      <PanelSectionRow>
        <div style={{ fontSize: "0.8em", opacity: 0.7 }}>
          Saved in {game.name}'s launch options. Applies the next time the game starts.
        </div>
      </PanelSectionRow>
    </>
  );
}
