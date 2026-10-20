import {
  PanelSection,
  PanelSectionRow,
  ButtonItem,
  DropdownItem,
  SliderField,
  ToggleField,
} from "@decky/ui";
import { callable } from "@decky/api";
import { ReactNode, useEffect, useRef, useState } from "react";
import {
  FRAMEGEN_TWEAKS,
  Game,
  LaunchTweaks,
  TWEAKS,
  Tweak,
  fpsText,
  launchOptionsOf,
  readTweaks,
  runningGame,
  writeTweaks,
} from "./launchOptions";

interface LsfgStatus {
  ok: boolean;
  error?: string;
  installed?: boolean;
  configPath?: string;
  configError?: string;
  dll?: string | null;
  allowFp16?: boolean;
}

interface LsfgProfile {
  name: string;
  multiplier: number;
  flow_scale: number;
  performance_mode: boolean;
  override_present_mode: boolean;
  preserve_swapchain_image_count: boolean;
  color_space: string;
  transfer_function: string;
}

interface Shadow { profile: string; entries: string[] }
interface ProfileReply {
  ok: boolean;
  error?: string;
  profile?: LsfgProfile | null;
  shadowedBy?: Shadow[];
}
interface WriteReply { ok: boolean; error?: string }
interface FrameCapReply { ok: boolean; error?: string; cap: number; refresh: number | null }

export const lsfgStatus = callable<[], LsfgStatus>("lsfg_status");
const lsfgGet = callable<[appid: string], ProfileReply>("lsfg_get");
const lsfgEnable = callable<[appid: string, name: string], ProfileReply>("lsfg_enable");
const lsfgDisable = callable<[appid: string], ProfileReply>("lsfg_disable");
const lsfgClaim = callable<[appid: string], ProfileReply>("lsfg_claim");
const lsfgSet = callable<[appid: string, key: string, value: unknown], ProfileReply>("lsfg_set");
const lsfgSetGlobal = callable<[key: string, value: unknown], WriteReply>("lsfg_set_global");
const frameCapGet = callable<[appid: string], FrameCapReply>("frame_cap_get");
const frameCapSet = callable<[appid: string, cap: number], WriteReply>("frame_cap_set");

const POLL_MS = 2000;
const SLIDER_DEBOUNCE_MS = 400;
const FALLBACK_MAX_FRAME_CAP = 60;

const COLOR_SPACES = [
  { data: "srgb", label: "sRGB" },
  { data: "hdr10", label: "HDR10" },
  { data: "scrgb", label: "scRGB" },
  { data: "dcip3", label: "DCI-P3" },
];
const TRANSFER_FUNCTIONS = [
  { data: "srgb", label: "sRGB" },
  { data: "linear", label: "Linear" },
  { data: "pq", label: "HDR10 PQ" },
  { data: "hlg", label: "HDR10 HLG" },
  { data: "scrgbnl", label: "scRGB non-linear" },
  { data: "dcip3", label: "DCI-P3" },
];
const MULTIPLIER_NOTCHES = [2, 3, 4].map((value, notchIndex) => ({ notchIndex, value, label: `${value}x` }));

const autoFrameCap = (multiplier: number, refresh: number | null) =>
  refresh ? Math.round((refresh / multiplier) * 100) / 100 : 0;

const frameCapFor = (setting: number, multiplier: number, refresh: number | null) =>
  setting > 0 ? setting : autoFrameCap(multiplier, refresh);

export const syncFrameCap = async (appid: string) => {
  const [reply, cap] = await Promise.all([lsfgGet(appid), frameCapGet(appid)]);
  if (!reply.ok || !reply.profile || !cap.ok) return;
  const options = await launchOptionsOf(Number(appid));
  if (options === null) return;
  const tweaks = readTweaks(options);
  const frameCap = frameCapFor(cap.cap, reply.profile.multiplier, cap.refresh);
  if (tweaks.frameCap !== frameCap) {
    SteamClient.Apps.SetAppLaunchOptions(Number(appid), writeTweaks(options, { ...tweaks, frameCap }));
  }
};


const Note = ({ children, error }: { children: ReactNode; error?: boolean }) => (
  <div style={{ fontSize: "0.8em", opacity: error ? 1 : 0.7, color: error ? "#ff6b6b" : undefined }}>
    {children}
  </div>
);

type SliderKey = "multiplier" | "flow_scale" | "frame_cap";

export function FrameGenTab() {
  const [status, setStatus] = useState<LsfgStatus | null>(null);
  const [game, setGame] = useState<Game | null>(runningGame);
  const [profile, setProfile] = useState<LsfgProfile | null>(null);
  const [shadows, setShadows] = useState<Shadow[]>([]);
  const [launchOptions, setLaunchOptions] = useState<string | null>(null);
  const [capSetting, setCapSetting] = useState<number | null>(null);
  const [refresh, setRefresh] = useState<number | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [draft, setDraft] = useState<Partial<Record<SliderKey, number>>>({});
  const timers = useRef<Partial<Record<SliderKey, ReturnType<typeof setTimeout>>>>({});
  const shownAppid = useRef<string | undefined>(game?.appid);

  const clearTimers = () => {
    for (const timer of Object.values(timers.current)) if (timer) clearTimeout(timer);
    timers.current = {};
  };

  useEffect(() => {
    void lsfgStatus().then(setStatus);
    const timer = setInterval(() => {
      const next = runningGame();
      setGame((prev) => (prev?.appid === next?.appid ? prev : next));
    }, POLL_MS);
    return () => {
      clearInterval(timer);
      clearTimers();
    };
  }, []);

  useEffect(() => {
    clearTimers();
    setProfile(null);
    setShadows([]);
    setDraft({});
    setLaunchOptions(null);
    setCapSetting(null);
    shownAppid.current = game?.appid;
    if (!game) return;
    let live = true;
    void frameCapGet(game.appid).then((reply) => {
      if (!live) return;
      if (reply.ok) {
        setCapSetting(reply.cap);
        setRefresh(reply.refresh);
      } else {
        setError(reply.error || "could not read the frame cap");
      }
    });
    void lsfgGet(game.appid).then((reply) => {
      if (!live) return;
      if (reply.ok) {
        setProfile(reply.profile ?? null);
        setShadows(reply.shadowedBy ?? []);
      } else {
        setError(reply.error || "could not read the lsfg-vk configuration");
      }
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
  }, [game?.appid]);

  const apply = async (fn: () => Promise<ProfileReply>) => {
    setBusy(true);
    try {
      const reply = await fn();
      if (reply.ok) {
        setProfile(reply.profile ?? null);
        if (reply.shadowedBy) setShadows(reply.shadowedBy);
        setError(null);
      } else {
        setError(reply.error || "write failed");
      }
    } finally {
      setBusy(false);
    }
  };

  const setField = (key: keyof LsfgProfile, value: unknown) => {
    if (game) void apply(() => lsfgSet(game.appid, key, value));
  };

  const queue = (key: SliderKey, value: number, commit: () => Promise<void>) => {
    setDraft((d) => ({ ...d, [key]: value }));
    const pending = timers.current[key];
    if (pending) clearTimeout(pending);
    timers.current[key] = setTimeout(() => {
      delete timers.current[key];
      void commit().finally(() =>
        setDraft((d) => {
          const { [key]: _, ...rest } = d;
          return rest;
        }),
      );
    }, SLIDER_DEBOUNCE_MS);
  };

  const queueField = (key: "multiplier" | "flow_scale", value: number) => {
    if (!game) return;
    const appid = game.appid;
    queue(key, value, async () => {
      const reply = await lsfgSet(appid, key, value);
      if (shownAppid.current !== appid) return;
      if (reply.ok) {
        setProfile(reply.profile ?? null);
        setError(null);
      } else {
        setError(reply.error || "write failed");
      }
    });
  };

  const queueFrameCap = (value: number) => {
    if (!game) return;
    const appid = game.appid;
    queue("frame_cap", value, async () => {
      const reply = await frameCapSet(appid, value);
      if (shownAppid.current !== appid) return;
      if (reply.ok) {
        setCapSetting(value);
        setError(null);
      } else {
        setError(reply.error || "write failed");
      }
    });
  };

  const setGlobal = async (key: string, value: unknown) => {
    setBusy(true);
    try {
      const reply = await lsfgSetGlobal(key, value);
      if (!reply.ok) setError(reply.error || "write failed");
      setStatus(await lsfgStatus());
    } finally {
      setBusy(false);
    }
  };

  const tweaks = readTweaks(launchOptions ?? "");
  const wantedCap =
    !busy && profile && capSetting !== null ? frameCapFor(capSetting, profile.multiplier, refresh) : null;

  const setTweaks = (next: LaunchTweaks) => {
    if (!game || launchOptions === null) return;
    const options = writeTweaks(launchOptions, next);
    SteamClient.Apps.SetAppLaunchOptions(Number(game.appid), options);
    setLaunchOptions(options);
  };

  useEffect(() => {
    if (wantedCap === null || launchOptions === null || tweaks.frameCap === wantedCap) return;
    setTweaks({ ...tweaks, frameCap: wantedCap });
  }, [wantedCap, launchOptions]);

  const withTweak = (flags: Record<string, boolean>, tweak: Tweak, on: boolean) => {
    const next = { ...flags, [tweak.key]: on };
    if (on && tweak.excludes) next[tweak.excludes] = false;
    return next;
  };

  const toggleTweak = (tweak: Tweak, on: boolean) => {
    if (tweaks.flags[tweak.key] === on) return;
    setTweaks({ ...tweaks, flags: withTweak(tweaks.flags, tweak, on) });
  };

  const toggleFrameGen = (on: boolean) => {
    if (!game) return;
    void apply(() => (on ? lsfgEnable(game.appid, game.name) : lsfgDisable(game.appid)));
    const flags = TWEAKS.filter((t) => FRAMEGEN_TWEAKS.includes(t.key)).reduce(
      (acc, tweak) => withTweak(acc, tweak, on),
      tweaks.flags,
    );
    setTweaks({ ...tweaks, flags, frameCap: on ? tweaks.frameCap : 0 });
  };

  if (!status) {
    return (
      <PanelSection title="Frame generation">
        <PanelSectionRow>
          <div>Loading…</div>
        </PanelSectionRow>
      </PanelSection>
    );
  }

  const blocked = busy || Boolean(status.configError);
  const multiplier = draft.multiplier ?? profile?.multiplier ?? 2;
  const flowScale = draft.flow_scale ?? profile?.flow_scale ?? 1;
  const frameCap = draft.frame_cap ?? capSetting ?? 0;
  const maxFrameCap = Math.max(refresh ? Math.round(refresh) : FALLBACK_MAX_FRAME_CAP, capSetting ?? 0);
  const frameCapText =
    frameCap > 0
      ? `${frameCap} fps`
      : refresh
        ? `Auto: ${fpsText(autoFrameCap(multiplier, refresh))} fps (${fpsText(refresh)} Hz ÷ ${multiplier})`
        : "Auto: refresh rate unknown, no cap";

  return (
    <>
      <PanelSection title="Frame generation">
        {status.configError && (
          <PanelSectionRow>
            <Note error>{status.configError}</Note>
          </PanelSectionRow>
        )}
        {!status.dll && (
          <PanelSectionRow>
            <Note>lsfg-vk.dll was not found. Install Lossless Scaling from Steam.</Note>
          </PanelSectionRow>
        )}

        {!game ? (
          <PanelSectionRow>
            <Note>Launch a game to set up frame generation for it.</Note>
          </PanelSectionRow>
        ) : (
          <>
            <PanelSectionRow>
              <ToggleField
                label="Frame generation"
                description={profile ? `Own profile for ${game.name}` : `Off for ${game.name}`}
                checked={Boolean(profile)}
                disabled={blocked || launchOptions === null}
                onChange={toggleFrameGen}
              />
            </PanelSectionRow>

            {shadows.length > 0 && (
              <>
                <PanelSectionRow>
                  <Note error>
                    {`lsfg-vk uses ${shadows
                      .map((s) => `"${s.profile}" (${s.entries.join(", ")})`)
                      .join(" and ")} for this game: executable matches win over the app id${
                      profile ? ", so the settings below are ignored" : ""
                    }.`}
                  </Note>
                </PanelSectionRow>
                {profile && (
                  <PanelSectionRow>
                    <ButtonItem layout="below" disabled={blocked} onClick={() => apply(() => lsfgClaim(game.appid))}>
                      Use this game's profile
                    </ButtonItem>
                  </PanelSectionRow>
                )}
              </>
            )}

            {profile && (
              <>
                <PanelSectionRow>
                  <SliderField
                    label="Multiplier"
                    value={multiplier}
                    min={2}
                    max={4}
                    step={1}
                    notchCount={MULTIPLIER_NOTCHES.length}
                    notchLabels={MULTIPLIER_NOTCHES}
                    notchTicksVisible={true}
                    onChange={(value) => queueField("multiplier", value)}
                  />
                </PanelSectionRow>
                <PanelSectionRow>
                  <SliderField
                    label="Base frame cap"
                    description={frameCapText}
                    value={frameCap}
                    min={0}
                    max={maxFrameCap}
                    step={1}
                    disabled={capSetting === null || launchOptions === null}
                    onChange={queueFrameCap}
                  />
                </PanelSectionRow>
                <PanelSectionRow>
                  <SliderField
                    label="Flow scale"
                    value={Math.round(flowScale * 100)}
                    min={25}
                    max={100}
                    step={5}
                    showValue={true}
                    valueSuffix="%"
                    onChange={(value) => queueField("flow_scale", value / 100)}
                  />
                </PanelSectionRow>
                <PanelSectionRow>
                  <ToggleField
                    label="Performance mode"
                    description="Lighter model: faster, lower quality"
                    checked={profile.performance_mode}
                    disabled={blocked}
                    onChange={(on) => setField("performance_mode", on)}
                  />
                </PanelSectionRow>
                <PanelSectionRow>
                  <ToggleField
                    label="Force FIFO present mode"
                    checked={profile.override_present_mode}
                    disabled={blocked}
                    onChange={(on) => setField("override_present_mode", on)}
                  />
                </PanelSectionRow>
                <PanelSectionRow>
                  <DropdownItem
                    label="Color space"
                    rgOptions={COLOR_SPACES}
                    selectedOption={profile.color_space}
                    disabled={blocked}
                    onChange={(opt) => setField("color_space", opt.data)}
                  />
                </PanelSectionRow>
                <PanelSectionRow>
                  <DropdownItem
                    label="Transfer function"
                    rgOptions={TRANSFER_FUNCTIONS}
                    selectedOption={profile.transfer_function}
                    disabled={blocked}
                    onChange={(opt) => setField("transfer_function", opt.data)}
                  />
                </PanelSectionRow>
                <PanelSectionRow>
                  <ToggleField
                    label="Preserve swapchain image count"
                    checked={profile.preserve_swapchain_image_count}
                    disabled={blocked}
                    onChange={(on) => setField("preserve_swapchain_image_count", on)}
                  />
                </PanelSectionRow>
              </>
            )}

            <PanelSectionRow>
              <Note>
                Turning frame generation on or off takes effect the next time the game starts, and
                also switches gamescope WSI off and turnip safe preemption on for the game, or back.
                The base frame cap is for DXVK and vkd3d-proton games and applies the next time the
                game starts. Other setting changes apply live.
              </Note>
            </PanelSectionRow>
          </>
        )}

        {error && (
          <PanelSectionRow>
            <Note error>{error}</Note>
          </PanelSectionRow>
        )}
      </PanelSection>

      {game && (
        <PanelSection title="Launch options">
          {TWEAKS.map((tweak) => (
            <PanelSectionRow key={tweak.key}>
              <ToggleField
                label={tweak.label}
                checked={tweaks.flags[tweak.key]}
                disabled={launchOptions === null}
                onChange={(on) => toggleTweak(tweak, on)}
              />
            </PanelSectionRow>
          ))}
          <PanelSectionRow>
            <Note>Saved in {game.name}'s Steam launch options. Applies the next time the game starts.</Note>
          </PanelSectionRow>
        </PanelSection>
      )}

      <PanelSection title="lsfg-vk">
        <PanelSectionRow>
          <ToggleField
            label="Allow FP16"
            description="Applies to every game"
            checked={status.allowFp16 ?? true}
            disabled={blocked}
            onChange={(on) => setGlobal("allow_fp16", on)}
          />
        </PanelSectionRow>
      </PanelSection>
    </>
  );
}
