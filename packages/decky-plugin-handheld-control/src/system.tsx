import {
  ButtonItem,
  DialogBody,
  DialogButton,
  DialogFooter,
  DialogHeader,
  DropdownItem,
  Focusable,
  ModalRoot,
  PanelSection,
  PanelSectionRow,
  ToggleField,
  showModal,
} from "@decky/ui";
import { callable } from "@decky/api";
import { ReactNode, useEffect, useRef, useState } from "react";

export interface SettingsStatus {
  UsbFileTransferAvailable: boolean;
  UsbFileTransferAllowed: boolean;
  UsbFileTransferActive: boolean;
  SshAvailable: boolean;
  SshActive: boolean;
  SshAuthorizedKeys: number;
  SshAddresses: string[];
  ControllerAvailable: boolean;
  ControllerType: string;
  ControllerTypes: [string, string][];
  ControllerTargets: string[];
  CalibrationSupported: boolean;
  CalibrationSaved: boolean;
}

interface StatusReply { ok: boolean; available?: boolean; error?: string; status?: SettingsStatus }
interface WriteReply { ok: boolean; error?: string }
interface Control { value: number; min: number; max: number }
interface Seen { min: number; max: number; center: number }
type Controls = Record<string, Control>;
type Capture = Record<string, Seen>;
interface ReadReply { ok: boolean; error?: string; controls?: Controls; capture?: Capture | null }
interface CalibrationReply { ok: boolean; error?: string; supported?: boolean; saved?: boolean }

export const settingsStatus = callable<[], StatusReply>("settings_status");
const settingsSet = callable<[what: string, value: unknown], WriteReply>("settings_set");
const calibrationState = callable<[], CalibrationReply>("calibration_state");
const calibrationSession = callable<[on: boolean], WriteReply>("calibration_session");
const calibrationRead = callable<[], ReadReply>("calibration_read");
const calibrationSave = callable<[capture: Capture], WriteReply>("calibration_save");
const calibrationReset = callable<[], WriteReply>("calibration_reset");

const POLL_MS = 3000;
const READ_MS = 150;
const CAPTURE_SECONDS = 15;

const CONTROLS: [string, string][] = [
  ["left_x", "Left stick X"],
  ["left_y", "Left stick Y"],
  ["right_x", "Right stick X"],
  ["right_y", "Right stick Y"],
  ["left_trigger", "Left trigger"],
  ["right_trigger", "Right trigger"],
];

const Note = ({ children, error }: { children: ReactNode; error?: boolean }) => (
  <div style={{ fontSize: "0.8em", opacity: error ? 1 : 0.7, color: error ? "#ff6b6b" : undefined }}>
    {children}
  </div>
);

const Row = ({ children }: { children: ReactNode }) => (
  <Focusable style={{ display: "flex", gap: "8px", marginTop: "8px" }} flow-children="horizontal">
    {children}
  </Focusable>
);

function ControlBar({ label, control, seen }: { label: string; control?: Control; seen?: Seen }) {
  const low = control?.min ?? -1;
  const high = control?.max ?? 1;
  const at = (v: number) => `${Math.max(0, Math.min(100, ((v - low) / (high - low || 1)) * 100))}%`;
  return (
    <div style={{ margin: "6px 0" }}>
      <div style={{ display: "flex", justifyContent: "space-between", fontSize: "0.85em" }}>
        <span>{label}</span>
        <span style={{ opacity: 0.7 }}>
          {control?.value ?? "?"}
          {seen ? ` · seen ${seen.min} to ${seen.max}` : ""}
        </span>
      </div>
      <div style={{ position: "relative", height: "8px", borderRadius: "4px", background: "rgba(255,255,255,0.12)" }}>
        {seen && (
          <div
            style={{
              position: "absolute",
              left: at(seen.min),
              width: `calc(${at(seen.max)} - ${at(seen.min)})`,
              height: "100%",
              borderRadius: "4px",
              background: "rgba(26,159,255,0.45)",
            }}
          />
        )}
        {control && (
          <div
            style={{
              position: "absolute",
              left: `calc(${at(control.value)} - 3px)`,
              width: "6px",
              height: "100%",
              borderRadius: "3px",
              background: "#1a9fff",
            }}
          />
        )}
      </div>
    </div>
  );
}

function CalibrationModal({ closeModal, onChanged }: { closeModal?: () => void; onChanged: () => void }) {
  const [saved, setSaved] = useState(false);
  const [controls, setControls] = useState<Controls>({});
  const [capture, setCapture] = useState<Capture | null>(null);
  const [left, setLeft] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const capturing = useRef(false);

  const loadState = async () => {
    const reply = await calibrationState();
    if (reply.ok) setSaved(Boolean(reply.saved));
    else setError(reply.error || "could not read the calibration");
  };

  useEffect(() => {
    void loadState();
    const timer = setInterval(async () => {
      const reply = await calibrationRead();
      if (!reply.ok) return;
      if (reply.controls) setControls(reply.controls);
      if (capturing.current && reply.capture) setCapture(reply.capture);
    }, READ_MS);
    return () => {
      clearInterval(timer);
      if (capturing.current) void calibrationSession(false);
    };
  }, []);

  useEffect(() => {
    if (left <= 0) return;
    const timer = setTimeout(() => {
      if (left > 1) {
        setLeft(left - 1);
        return;
      }
      setLeft(0);
      capturing.current = false;
      void calibrationSession(false);
    }, 1000);
    return () => clearTimeout(timer);
  }, [left]);

  const start = async () => {
    setError(null);
    setCapture(null);
    const reply = await calibrationSession(true);
    if (!reply.ok) {
      setError(reply.error || "could not start calibration");
      return;
    }
    capturing.current = true;
    setLeft(CAPTURE_SECONDS);
  };

  const save = async () => {
    if (!capture) return;
    const reply = await calibrationSave(capture);
    setError(reply.ok ? null : reply.error || "could not save the calibration");
    if (reply.ok) {
      setCapture(null);
      await loadState();
      onChanged();
    }
  };

  const reset = async () => {
    const reply = await calibrationReset();
    setError(reply.ok ? null : reply.error || "could not reset the calibration");
    await loadState();
    onChanged();
  };

  const busy = left > 0;

  return (
    <ModalRoot closeModal={closeModal}>
      <DialogHeader>Controller calibration</DialogHeader>
      <DialogBody>
        <Note>
          {busy
            ? `Capturing for ${left} s: move both sticks around their edges in full circles, and press both triggers all the way.`
            : capture
              ? "Captured. Save it, or try again."
              : "Leave the sticks and triggers alone, then start. The controls stop driving the menu until capture ends."}
        </Note>
        {CONTROLS.map(([key, label]) => (
          <ControlBar key={key} label={label} control={controls[key]} seen={capture?.[key]} />
        ))}
        {error && <Note error>{error}</Note>}
        <Row>
          <DialogButton disabled={busy} onClick={() => void start()}>
            {capture ? "Try again" : "Start"}
          </DialogButton>
          <DialogButton disabled={busy || !capture} onClick={() => void save()}>
            Save
          </DialogButton>
          {saved && (
            <DialogButton disabled={busy} onClick={() => void reset()}>
              Reset to factory
            </DialogButton>
          )}
        </Row>
        <Note>{saved ? "A saved calibration is applied at every boot." : "Using the driver's factory calibration."}</Note>
      </DialogBody>
      <DialogFooter>
        <DialogButton disabled={busy} onClick={closeModal}>
          Close
        </DialogButton>
      </DialogFooter>
    </ModalRoot>
  );
}

export function SystemTab() {
  const [status, setStatus] = useState<SettingsStatus | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const refresh = async () => {
    const reply = await settingsStatus();
    if (reply.ok && reply.status) setStatus(reply.status);
    else setError(reply.error || "could not reach handheld-settingsd");
  };

  useEffect(() => {
    void refresh();
    const timer = setInterval(refresh, POLL_MS);
    return () => clearInterval(timer);
  }, []);

  const set = async (what: string, value: unknown) => {
    setBusy(true);
    try {
      const reply = await settingsSet(what, value);
      setError(reply.ok ? null : reply.error || "write failed");
      await refresh();
    } finally {
      setBusy(false);
    }
  };

  if (!status) {
    return (
      <PanelSection title="System">
        <PanelSectionRow>{error ? <Note error>{error}</Note> : <div>Loading…</div>}</PanelSectionRow>
      </PanelSection>
    );
  }

  const keys = status.SshAuthorizedKeys;
  const sshDescription = [
    "Keys only, until reboot.",
    keys < 0 ? "Authorized keys unreadable." : keys === 0 ? "No keys in ~/.ssh/authorized_keys yet." : `${keys} authorized key${keys === 1 ? "" : "s"}.`,
    status.SshActive && status.SshAddresses.length ? status.SshAddresses.join(", ") : "",
  ]
    .filter(Boolean)
    .join(" ");

  return (
    <PanelSection title="System">
      {status.UsbFileTransferAvailable && (
        <PanelSectionRow>
          <ToggleField
            label="USB file transfer"
            description={
              !status.UsbFileTransferAllowed
                ? "Off, also after a reboot"
                : status.UsbFileTransferActive
                  ? "Connected: your home folder is visible to the computer"
                  : "Starts when plugged into a computer"
            }
            checked={status.UsbFileTransferAllowed}
            disabled={busy}
            onChange={(on) => void set("usb", on)}
          />
        </PanelSectionRow>
      )}
      {status.SshAvailable && (
        <PanelSectionRow>
          <ToggleField
            label="SSH"
            description={sshDescription}
            checked={status.SshActive}
            disabled={busy}
            onChange={(on) => void set("ssh", on)}
          />
        </PanelSectionRow>
      )}
      <PanelSectionRow>
        <ToggleField
          label="Stealth firewall"
          description="Default-deny firewall, hidden hostname, random MAC. Not wired up yet."
          checked={false}
          disabled={true}
          onChange={() => undefined}
        />
      </PanelSectionRow>
      <PanelSectionRow>
        <ToggleField
          label="Stealth firewall on boot"
          description="Come up locked down at every boot. Not wired up yet."
          checked={false}
          disabled={true}
          onChange={() => undefined}
        />
      </PanelSectionRow>
      {status.ControllerAvailable && (
        <PanelSectionRow>
          <DropdownItem
            label="Controller type"
            description="What games see the built-in controls as. Applies now in Game Mode."
            rgOptions={status.ControllerTypes.map(([data, label]) => ({ data, label }))}
            selectedOption={status.ControllerType}
            disabled={busy}
            onChange={(opt) => void set("controller", opt.data)}
          />
        </PanelSectionRow>
      )}
      {status.CalibrationSupported && (
        <PanelSectionRow>
          <ButtonItem
            layout="below"
            description={status.CalibrationSaved ? "Using a saved calibration" : "Using the factory calibration"}
            onClick={() => showModal(<CalibrationModal onChanged={() => void refresh()} />)}
          >
            Calibrate controller
          </ButtonItem>
        </PanelSectionRow>
      )}
      {error && (
        <PanelSectionRow>
          <Note error>{error}</Note>
        </PanelSectionRow>
      )}
    </PanelSection>
  );
}
