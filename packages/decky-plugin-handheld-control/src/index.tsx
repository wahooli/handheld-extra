import {
  PanelSection,
  PanelSectionRow,
  DropdownItem,
  ButtonItem,
  SliderField,
  ToggleField,
  DialogButton,
  Focusable,
  Router,
  staticClasses,
} from "@decky/ui";
import { callable, definePlugin } from "@decky/api";
import { useEffect, useRef, useState } from "react";
import { FaFan } from "react-icons/fa";
import { FrameGenTab, lsfgStatus, syncFrameCap } from "./lsfg";
import { GameLaunchSettings } from "./compat";
import { GameTuning, PowerTuning } from "./tuning";
import { SystemTab, settingsStatus } from "./system";
import { launchOptionsOf, readTweaks } from "./launchOptions";

interface Status {
  Profile?: string;
  ProfileLabel?: string;
  SocClass?: string;
  HasFan?: boolean;
  HasGpu?: boolean;
  FanCurve?: string;
  FanCurveSource?: string;
  FanPwm?: number;
  FanRpm?: number;
  TemperatureC?: number;
  GpuClockMhz?: number;
  GpuPerformanceLevel?: string;
  HasCpuFreq?: boolean;
  CpuPerformanceLevel?: string;
  CpuClockMhz?: number;
  CpuMaxMhz?: number;
  ManualCpuClock?: number;
  ManualCpuClockMin?: number;
  ManualCpuClockMax?: number;
}

interface StatusReply { ok: boolean; error?: string; status?: Status }
interface OptionsReply { ok: boolean; profiles: string[]; fanCurves: string[] }
interface WriteReply { ok: boolean; error?: string }
interface GameReply { ok: boolean; enabled: boolean }
interface RunningGame { appid: string; name: string; enabled: boolean }
interface SchedulerReply {
  ok: boolean;
  error?: string;
  available: boolean;
  current?: string;
  mode?: string;
  domain?: string;
  schedulers?: string[];
}

const getStatus = callable<[], StatusReply>("get_status");
const getOptions = callable<[], OptionsReply>("get_options");
const setProfile = callable<[name: string], WriteReply>("set_profile");
const setFanCurve = callable<[name: string], WriteReply>("set_fan_curve");
const setCpu = callable<[value: string], WriteReply>("set_cpu");
const reloadConfig = callable<[], WriteReply>("reload_config");
const getGame = callable<[appid: string], GameReply>("get_game");
const setGameEnabled = callable<[appid: string, name: string, enabled: boolean], WriteReply>(
  "set_game_enabled",
);
const gameStarted = callable<[appid: string, cores: string], WriteReply>("game_started");
const gameStopped = callable<[appid: string], WriteReply>("game_stopped");
const syncRunning = callable<[appid: string, cores: string], WriteReply>("sync_running");
const getScheduler = callable<[], SchedulerReply>("scx_status");
const setScheduler = callable<[name: string], WriteReply>("scx_set");

const POLL_MS = 2000;

const FOLLOW_PROFILE = "profile";

const KERNEL_SCHEDULER = "";

const schedulerLabel = (name: string) => {
  const short = name.replace(/^scx_/, "");
  return short[0].toUpperCase() + short.slice(1);
};

const PIN_DEBOUNCE_MS = 400;

const PIN_STEP_MHZ = 100;

const floorStep = (mhz: number) => Math.floor(mhz / PIN_STEP_MHZ) * PIN_STEP_MHZ;
const ceilStep = (mhz: number) => Math.ceil(mhz / PIN_STEP_MHZ) * PIN_STEP_MHZ;

type Tab = "performance" | "framegen" | "system";

const TABS: { id: Tab; label: string; short: string }[] = [
  { id: "performance", label: "Performance", short: "Performance" },
  { id: "system", label: "System", short: "System" },
  { id: "framegen", label: "Frame generation", short: "Frame gen" },
];

let lastTab: Tab = "performance";

function Content() {
  const [lsfgInstalled, setLsfgInstalled] = useState(false);
  const [settingsAvailable, setSettingsAvailable] = useState(false);
  const [tab, setTab] = useState<Tab>(lastTab);

  useEffect(() => {
    let live = true;
    void lsfgStatus().then((reply) => {
      if (live) setLsfgInstalled(reply.ok && Boolean(reply.installed));
    });
    void settingsStatus().then((reply) => {
      if (live) setSettingsAvailable(reply.ok);
    });
    return () => {
      live = false;
    };
  }, []);

  const choose = (next: Tab) => {
    lastTab = next;
    setTab(next);
  };

  const tabs = TABS.filter(({ id }) => (id !== "framegen" || lsfgInstalled) && (id !== "system" || settingsAvailable));
  const active: Tab = tabs.some(({ id }) => id === tab) ? tab : "performance";

  return (
    <>
      {tabs.length > 1 && (
        <PanelSection>
          <PanelSectionRow>
            <Focusable style={{ display: "flex", gap: "6px" }} flow-children="horizontal">
              {tabs.map(({ id, label, short }) => (
                <DialogButton
                  key={id}
                  style={{
                    flex: 1,
                    minWidth: 0,
                    padding: "6px 4px",
                    fontSize: "0.85em",
                    opacity: active === id ? 1 : 0.55,
                  }}
                  onClick={() => choose(id)}
                >
                  {tabs.length > 2 ? short : label}
                </DialogButton>
              ))}
            </Focusable>
          </PanelSectionRow>
        </PanelSection>
      )}
      {active === "performance" && <PerformanceTab />}
      {active === "framegen" && <FrameGenTab />}
      {active === "system" && <SystemTab />}
    </>
  );
}

function PerformanceTab() {
  const [status, setStatus] = useState<Status | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [profiles, setProfiles] = useState<string[]>([]);
  const [fanCurves, setFanCurves] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);
  const [pinMhz, setPinMhz] = useState<number | null>(null);
  const [game, setGame] = useState<RunningGame | null>(null);
  const [scheduler, setSchedulerState] = useState<SchedulerReply | null>(null);
  const [schedulerError, setSchedulerError] = useState<string | null>(null);
  const pinTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const schedulerWanted = useRef(true);

  const refreshGame = async () => {
    const app = Router.MainRunningApp;
    if (!app) {
      setGame(null);
      return;
    }
    const reply = await getGame(String(app.appid));
    setGame({ appid: String(app.appid), name: app.display_name, enabled: reply.ok && reply.enabled });
  };

  const refreshScheduler = async () => {
    if (!schedulerWanted.current) return;
    const reply = await getScheduler();
    schedulerWanted.current = reply.available;
    setSchedulerState(reply);
  };

  const refresh = async () => {
    const [reply] = await Promise.all([getStatus(), refreshScheduler()]);
    if (reply.ok && reply.status) {
      setStatus(reply.status);
      setError(null);
    } else {
      setError(reply.error ?? "unknown error");
    }
    await refreshGame();
  };

  useEffect(() => {
    let live = true;
    (async () => {
      const opts = await getOptions();
      if (!live) return;
      setProfiles(opts.profiles ?? []);
      setFanCurves(opts.fanCurves ?? []);
    })();
    refresh();
    const timer = setInterval(refresh, POLL_MS);
    return () => {
      live = false;
      clearInterval(timer);
      if (pinTimer.current) clearTimeout(pinTimer.current);
    };
  }, []);

  const reloadOptions = async () => {
    const opts = await getOptions();
    setProfiles(opts.profiles ?? []);
    setFanCurves(opts.fanCurves ?? []);
    await refresh();
  };

  const write = async (fn: () => Promise<WriteReply>) => {
    setBusy(true);
    try {
      const reply = await fn();
      if (!reply.ok) setError(reply.error || "write failed");
      await refresh();
    } finally {
      setBusy(false);
    }
  };

  const chooseScheduler = async (name: string) => {
    setBusy(true);
    try {
      const reply = await setScheduler(name);
      setSchedulerError(reply.ok ? null : reply.error || "switch failed");
      await refreshScheduler();
    } finally {
      setBusy(false);
    }
  };

  const queuePin = (mhz: number) => {
    setPinMhz(mhz);
    if (pinTimer.current) clearTimeout(pinTimer.current);
    pinTimer.current = setTimeout(() => {
      pinTimer.current = null;
      void (async () => {
        const reply = await setCpu(String(mhz));
        if (!reply.ok) setError(reply.error || "write failed");
        await refresh();
      })();
    }, PIN_DEBOUNCE_MS);
  };

  if (error && !status) {
    return (
      <PanelSection title="Handheld Control">
        <PanelSectionRow>
          <div style={{ fontSize: "0.8em", opacity: 0.8 }}>
            {error}
            <br />
            Check <code>systemctl status handheld-powerd</code>.
          </div>
        </PanelSectionRow>
      </PanelSection>
    );
  }

  if (!status) {
    return (
      <PanelSection title="Handheld Control">
        <PanelSectionRow>
          <div>Loading…</div>
        </PanelSectionRow>
      </PanelSection>
    );
  }

  const curveOptions = [
    { data: FOLLOW_PROFILE, label: "Follow power profile" },
    ...fanCurves.map((c) => ({ data: c, label: c[0].toUpperCase() + c.slice(1) })),
  ];
  const selectedCurve =
    status.FanCurveSource === "override" ? status.FanCurve ?? FOLLOW_PROFILE : FOLLOW_PROFILE;

  const pinLow = floorStep(status.ManualCpuClockMin ?? 0);
  const pinHigh = ceilStep(status.ManualCpuClockMax ?? 0);
  const pinned = status.CpuPerformanceLevel === "manual";
  const pinValue = pinMhz ?? (status.ManualCpuClock || status.CpuMaxMhz || pinHigh);
  const perGame = scheduler?.available
    ? "CPU pin, fan curve and CPU scheduler"
    : "CPU pin and fan curve";

  return (
    <PanelSection title="Handheld Control">
      {game && (
        <PanelSectionRow>
          <ToggleField
            label="Use per-game profile"
            description={
              game.enabled
                ? `${perGame} follow ${game.name}`
                : `${perGame} are shared by all games`
            }
            checked={game.enabled}
            disabled={busy}
            onChange={(on) =>
              write(() => {
                setPinMhz(null);
                return setGameEnabled(game.appid, game.name, on);
              })
            }
          />
        </PanelSectionRow>
      )}

      {profiles.length > 0 && (
        <PanelSectionRow>
          <DropdownItem
            label="Power profile"
            description={status.ProfileLabel}
            rgOptions={profiles.map((p) => ({
              data: p,
              label: p[0].toUpperCase() + p.slice(1),
            }))}
            selectedOption={status.Profile}
            disabled={busy}
            onChange={(opt) => write(() => setProfile(opt.data as string))}
          />
        </PanelSectionRow>
      )}

      {status.HasCpuFreq && pinHigh > 0 && (
        <>
          <PanelSectionRow>
            <ToggleField
              label="Pin CPU clock"
              description={
                pinned
                  ? `Pinned near ${status.ManualCpuClock} MHz`
                  : "Following the power profile"
              }
              checked={pinned}
              disabled={busy}
              onChange={(on) => write(() => setCpu(on ? String(pinValue) : "auto"))}
            />
          </PanelSectionRow>

          {pinned && (
            <PanelSectionRow>
              <SliderField
                label="CPU clock"
                value={pinValue}
                min={pinLow}
                max={pinHigh}
                step={PIN_STEP_MHZ}
                showValue={true}
                valueSuffix=" MHz"
                onChange={queuePin}
              />
            </PanelSectionRow>
          )}
        </>
      )}

      {scheduler?.available && scheduler.ok && (
        <PanelSectionRow>
          <DropdownItem
            label="CPU scheduler"
            description={
              scheduler.current
                ? scheduler.domain
                  ? `sched_ext: ${scheduler.current}, other work on cores ${scheduler.domain}`
                  : `sched_ext: ${scheduler.current}, ${scheduler.mode} mode`
                : "Kernel default (EEVDF)"
            }
            rgOptions={[
              { data: KERNEL_SCHEDULER, label: "Kernel default" },
              ...(scheduler.schedulers ?? []).map((s) => ({ data: s, label: schedulerLabel(s) })),
            ]}
            selectedOption={scheduler.current ?? KERNEL_SCHEDULER}
            disabled={busy}
            onChange={(opt) => void chooseScheduler(opt.data as string)}
          />
        </PanelSectionRow>
      )}

      {scheduler?.available && (scheduler.ok ? schedulerError : scheduler.error) && (
        <PanelSectionRow>
          <div style={{ fontSize: "0.8em", color: "#ff6b6b" }}>
            CPU scheduler: {scheduler.ok ? schedulerError : scheduler.error}
          </div>
        </PanelSectionRow>
      )}

      {game && <GameLaunchSettings game={game} />}
      {game && <GameTuning game={game} />}

      {status.HasFan && fanCurves.length > 0 && (
        <PanelSectionRow>
          <DropdownItem
            label="Fan curve"
            description={
              status.FanCurveSource === "override"
                ? `Pinned to ${status.FanCurve}`
                : `From profile: ${status.FanCurve}`
            }
            rgOptions={curveOptions}
            selectedOption={selectedCurve}
            disabled={busy}
            onChange={(opt) => write(() => setFanCurve(opt.data as string))}
          />
        </PanelSectionRow>
      )}

      <PanelSectionRow>
        <div style={{ fontSize: "0.8em", lineHeight: 1.6 }}>
          <div>Temperature: {status.TemperatureC ?? "?"} °C</div>
          {status.HasFan ? (
            <div>
              Fan: {status.FanPwm ?? 0}/255
              {status.FanRpm ? ` · ${status.FanRpm} rpm` : " · no tacho"}
            </div>
          ) : (
            <div>Fan: none detected</div>
          )}
          {status.HasCpuFreq && (
            <div>
              CPU: {status.CpuClockMhz ?? 0} MHz ({status.CpuPerformanceLevel})
            </div>
          )}
          {status.HasGpu && (
            <div>
              GPU: {status.GpuClockMhz ?? 0} MHz ({status.GpuPerformanceLevel})
            </div>
          )}
          <div style={{ opacity: 0.6 }}>{status.SocClass}</div>
        </div>
      </PanelSectionRow>

      {error && (
        <PanelSectionRow>
          <div style={{ fontSize: "0.8em", color: "#ff6b6b" }}>{error}</div>
        </PanelSectionRow>
      )}

      <PowerTuning
        profile={status.Profile ?? ""}
        fanCurve={status.FanCurve ?? ""}
        onChanged={() => void reloadOptions()}
      />

      <PanelSectionRow>
        <ButtonItem
          layout="below"
          disabled={busy}
          onClick={() => write(() => reloadConfig())}
        >
          Reload profile config
        </ButtonItem>
      </PanelSectionRow>
    </PanelSection>
  );
}

const coresOf = async (appid: string) => {
  const options = await launchOptionsOf(Number(appid));
  return options === null ? "" : readTweaks(options).cores;
};

export default definePlugin(() => {
  const running = Router.MainRunningApp;
  const runningId = running ? String(running.appid) : "";
  void (async () => syncRunning(runningId, runningId ? await coresOf(runningId) : ""))();
  const stoppedAt = new Map<string, number>();
  const lifetime = SteamClient.GameSessions.RegisterForAppLifetimeNotifications((n) => {
    const appid = String(n.unAppID);
    if (!n.bRunning) {
      stoppedAt.set(appid, Date.now());
      void gameStopped(appid);
      return;
    }
    const started = Date.now();
    void coresOf(appid).then((cores) => {
      if ((stoppedAt.get(appid) ?? 0) < started) void gameStarted(appid, cores);
    });
  });
  const actions = SteamClient.Apps.RegisterForGameActionStart((_action, appid) => {
    void syncFrameCap(appid);
  });

  return {
    name: "Handheld Control",
    titleView: <div className={staticClasses.Title}>Handheld Control</div>,
    content: <Content />,
    icon: <FaFan />,
    onDismount() {
      lifetime.unregister();
      actions.unregister();
    },
  };
});
