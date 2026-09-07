import {
  PanelSection,
  PanelSectionRow,
  DropdownItem,
  ButtonItem,
  SliderField,
  ToggleField,
  staticClasses,
} from "@decky/ui";
import { callable, definePlugin } from "@decky/api";
import { useEffect, useRef, useState } from "react";
import { FaFan } from "react-icons/fa";

// Mirrors the dict handheld-powerd's GetStatus returns. Only the fields this
// panel renders are declared; the CLI emits more.
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

const getStatus = callable<[], StatusReply>("get_status");
const getOptions = callable<[], OptionsReply>("get_options");
const setProfile = callable<[name: string], WriteReply>("set_profile");
const setFanCurve = callable<[name: string], WriteReply>("set_fan_curve");
const setCpu = callable<[value: string], WriteReply>("set_cpu");
const reloadConfig = callable<[], WriteReply>("reload_config");

// The panel polls rather than subscribing. handheld-powerd does emit
// PropertiesChanged, but the loader has no D-Bus bridge to forward it, and
// temperature/PWM change continuously anyway — there is no edge to subscribe to.
// 2s matches the daemon's own fan tick, so the numbers shown are never staler
// than one control cycle.
const POLL_MS = 2000;

// "profile" is the CLI's word for "clear the override and follow the active
// power profile". Not an empty string: an empty CLI argument is
// indistinguishable from no argument at all.
const FOLLOW_PROFILE = "profile";

// The CPU slider writes on a delay. Every step of a drag fires onChange, and
// each write is a D-Bus round trip that re-pins every cpufreq policy — so
// writing per step would pin the CPU to a dozen frequencies on the way to the
// one the user wanted. Long enough to coalesce a drag, short enough that
// releasing the stick feels like it took effect.
const PIN_DEBOUNCE_MS = 400;

// Slider granularity. cpufreq operating points are neither evenly spaced nor
// the same on both clusters, so there is no step size that lands on real ones;
// the daemon snaps each policy DOWN to its own table instead, which means the
// number here is a ceiling that holds rather than a frequency that exists.
// 100 MHz keeps the labels readable and the dpad usable.
const PIN_STEP_MHZ = 100;

// Round the slider ends outwards to whole steps. The daemon clamps anything
// outside the real range back into it, so overshooting at both ends costs
// nothing and buys round numbers plus a top notch that can actually reach the
// SoC's fastest operating point (4300.8 MHz is not 4300).
const floorStep = (mhz: number) => Math.floor(mhz / PIN_STEP_MHZ) * PIN_STEP_MHZ;
const ceilStep = (mhz: number) => Math.ceil(mhz / PIN_STEP_MHZ) * PIN_STEP_MHZ;

function Content() {
  const [status, setStatus] = useState<Status | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [profiles, setProfiles] = useState<string[]>([]);
  const [fanCurves, setFanCurves] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);
  // The slider's own value, so a drag is not fought by the 2s poll. Null until
  // the user touches it, at which point local state wins until the next mount.
  const [pinMhz, setPinMhz] = useState<number | null>(null);
  const pinTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const refresh = async () => {
    const reply = await getStatus();
    if (reply.ok && reply.status) {
      setStatus(reply.status);
      setError(null);
    } else {
      setError(reply.error ?? "unknown error");
    }
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
      // A pending pin must not fire into an unmounted panel — the write itself
      // would still land, which is worse than dropping it: the user closed the
      // panel at whatever value they were looking at.
      if (pinTimer.current) clearTimeout(pinTimer.current);
    };
  }, []);

  // Writes are serialised behind `busy` and followed by an immediate refresh:
  // the daemon applies synchronously, so waiting for the next poll would make a
  // dropdown appear to snap back to its old value for up to POLL_MS.
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

  // Deliberately not wrapped in `write`: that sets `busy`, and disabling the
  // control that is mid-drag is the one thing a debounced slider must not do.
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
  // The dropdown shows what is actually in force. When no override is set that
  // is the profile's curve, so select the "follow" entry rather than the curve
  // name — otherwise switching power profile would silently look like the user
  // had pinned a curve.
  const selectedCurve =
    status.FanCurveSource === "override" ? status.FanCurve ?? FOLLOW_PROFILE : FOLLOW_PROFILE;

  const pinLow = floorStep(status.ManualCpuClockMin ?? 0);
  const pinHigh = ceilStep(status.ManualCpuClockMax ?? 0);
  const pinned = status.CpuPerformanceLevel === "manual";
  // What the slider shows: the user's uncommitted drag, else the clock the
  // daemon has stored, else the ceiling already in force. Starting from the
  // ceiling rather than the top of the range matters — flipping the toggle on
  // then leaving it alone keeps the speed the profile was already allowing,
  // instead of pinning every cluster to the SoC maximum and staying there
  // across a reboot.
  const pinValue = pinMhz ?? (status.ManualCpuClock || status.CpuMaxMhz || pinHigh);

  return (
    <PanelSection title="Handheld Control">
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

      {/* The control the Deck UI has no concept of at all. `auto` is the power
          profile's clamp and governor; the pin holds scaling_min_freq and
          scaling_max_freq on one operating point per cluster, which is the only
          way to stop a game's frame pacing moving with the governor. */}
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

      {/* Hidden entirely when the device has no fan — qemu-virt, and any
          passively cooled handheld. An empty dropdown would be worse than none. */}
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
          {/* Each cluster snapped to its own table, so this is where the pin
              actually landed — usually below the slider's number. */}
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

      {/* Picks up hand edits to /etc/handheld/power-profiles.conf without a
          reboot, which is the whole point of that file being user-editable. */}
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

export default definePlugin(() => ({
  name: "Handheld Control",
  titleView: <div className={staticClasses.Title}>Handheld Control</div>,
  content: <Content />,
  icon: <FaFan />,
  onDismount() {},
}));
