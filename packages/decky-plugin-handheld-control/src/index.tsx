import {
  PanelSection,
  PanelSectionRow,
  DropdownItem,
  ButtonItem,
  staticClasses,
} from "@decky/ui";
import { callable, definePlugin } from "@decky/api";
import { useEffect, useState } from "react";
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
}

interface StatusReply { ok: boolean; error?: string; status?: Status }
interface OptionsReply { ok: boolean; profiles: string[]; fanCurves: string[] }
interface WriteReply { ok: boolean; error?: string }

const getStatus = callable<[], StatusReply>("get_status");
const getOptions = callable<[], OptionsReply>("get_options");
const setProfile = callable<[name: string], WriteReply>("set_profile");
const setFanCurve = callable<[name: string], WriteReply>("set_fan_curve");
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

function Content() {
  const [status, setStatus] = useState<Status | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [profiles, setProfiles] = useState<string[]>([]);
  const [fanCurves, setFanCurves] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);

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
