import {
  ButtonItem,
  DialogBody,
  DialogButton,
  DialogFooter,
  DialogHeader,
  DropdownItem,
  Focusable,
  ModalRoot,
  PanelSectionRow,
  SliderField,
  ToggleField,
  showModal,
} from "@decky/ui";
import { ReactNode, useEffect, useRef, useState } from "react";
import { Game } from "./launchOptions";
import {
  CurvePoint,
  FanSettings,
  PowerConfig,
  PowerProfile,
  WriteReply,
  getGameShader,
  getGameTuning,
  getPowerConfig,
  percentToPwm,
  pwmToPercent,
  resetPowerConfig,
  setGameShader,
  setGameTuning,
  setPowerConfig,
} from "./power";

const WRITE_DEBOUNCE_MS = 400;

const GAME_PRIORITIES = [
  { data: 0, label: "Normal" },
  { data: -5, label: "High" },
  { data: -10, label: "Higher" },
  { data: -15, label: "Highest" },
];

const GAMESCOPE_PRIORITIES = [
  { data: 0, label: "Normal" },
  { data: -5, label: "High" },
  { data: -10, label: "Higher" },
  { data: -20, label: "Highest" },
];

const nearest = (options: { data: number }[], value: number) =>
  options.reduce((best, o) => (Math.abs(o.data - value) < Math.abs(best.data - value) ? o : best)).data;

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

const usePowerConfig = () => {
  const [config, setConfig] = useState<PowerConfig | null>(null);
  const [error, setError] = useState<string | null>(null);
  const load = async () => {
    const reply = await getPowerConfig();
    if (reply.ok && reply.config) {
      setConfig(reply.config);
    } else {
      setError(reply.error || "could not read the power config");
    }
  };
  useEffect(() => {
    void load();
  }, []);
  return { config, error, setError, load };
};

const useDebounced = () => {
  const timers = useRef<Record<string, ReturnType<typeof setTimeout>>>({});
  useEffect(
    () => () => {
      for (const timer of Object.values(timers.current)) clearTimeout(timer);
    },
    [],
  );
  return (key: string, fn: () => void) => {
    clearTimeout(timers.current[key]);
    timers.current[key] = setTimeout(() => {
      delete timers.current[key];
      fn();
    }, WRITE_DEBOUNCE_MS);
  };
};

export function GameTuning({ game }: { game: Game }) {
  const [nice, setNice] = useState(0);
  const [irq, setIrq] = useState(false);
  const [cores, setCores] = useState("");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    void getGameTuning(game.appid).then((reply) => {
      if (!live || !reply.ok) return;
      setNice(reply.nice);
      setIrq(reply.irq);
      setCores(reply.cores);
    });
    return () => {
      live = false;
    };
  }, [game.appid]);

  const save = async (nextNice: number, nextIrq: boolean) => {
    setNice(nextNice);
    setIrq(nextIrq);
    const reply = await setGameTuning(game.appid, nextNice, nextIrq);
    setError(reply.ok ? null : reply.error || "could not apply the priority");
  };

  return (
    <>
      <PanelSectionRow>
        <DropdownItem
          label="Game priority"
          description="CPU priority of the game's threads, applied now"
          rgOptions={GAME_PRIORITIES}
          selectedOption={nearest(GAME_PRIORITIES, nice)}
          onChange={(opt) => void save(opt.data as number, irq)}
        />
      </PanelSectionRow>
      {cores && (
        <PanelSectionRow>
          <ToggleField
            label="Keep interrupts off its cores"
            description={`Hardware interrupts go to the cores outside ${cores} while it runs`}
            checked={irq}
            onChange={(on) => void save(nice, on)}
          />
        </PanelSectionRow>
      )}
      {error && (
        <PanelSectionRow>
          <Note error>{error}</Note>
        </PanelSectionRow>
      )}
    </>
  );
}

const NO_SHADER = "";

export function GameShader({ game }: { game: Game }) {
  const [shaders, setShaders] = useState<string[]>([]);
  const [shader, setShader] = useState(NO_SHADER);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    void getGameShader(game.appid).then((reply) => {
      if (!live) return;
      setShaders(reply.shaders ?? []);
      setShader(reply.shader ?? NO_SHADER);
      // An image without handheld-shader just has no dropdown.
      setError(reply.ok || !reply.available ? null : reply.error || "could not list the shaders");
    });
    return () => {
      live = false;
    };
  }, [game.appid]);

  const choose = async (name: string) => {
    setShader(name);
    const reply = await setGameShader(game.appid, name);
    setError(reply.ok ? null : reply.error || "could not apply the shader");
  };

  return (
    <>
      {shaders.length > 0 && (
        <PanelSectionRow>
          <DropdownItem
            label="Shader"
            description="Drawn over this game by gamescope, applied now"
            rgOptions={[
              { data: NO_SHADER, label: "None" },
              ...shaders.map((s) => ({ data: s, label: s.replace(/\.fx$/, "") })),
            ]}
            selectedOption={shader}
            onChange={(opt) => void choose(opt.data as string)}
          />
        </PanelSectionRow>
      )}
      {error && (
        <PanelSectionRow>
          <Note error>{error}</Note>
        </PanelSectionRow>
      )}
    </>
  );
}

const ratioPercent = (ratio: string) => Math.round(Number(ratio || 0) * 100);

function ProfileEditor({ closeModal, initial, onChanged }: {
  closeModal?: () => void;
  initial: string;
  onChanged: () => void;
}) {
  const { config, error, setError, load } = usePowerConfig();
  const [name, setName] = useState(initial);
  const [draft, setDraft] = useState<Partial<PowerProfile>>({});
  const debounce = useDebounced();

  useEffect(() => setDraft({}), [name]);

  const apply = async (reply: WriteReply) => {
    setError(reply.ok ? null : reply.error || "write failed");
    await load();
    onChanged();
  };

  const write = (key: keyof PowerProfile, value: string, delayed: boolean) => {
    setDraft((d) => ({ ...d, [key]: value }));
    const send = async () => {
      await apply(await setPowerConfig(`profile.${name}`, { [key]: value }));
      setDraft((d) => {
        const rest = { ...d };
        delete rest[key];
        return rest;
      });
    };
    if (delayed) debounce(key, () => void send());
    else void send();
  };

  if (!config || !config.profiles[name]) {
    return (
      <ModalRoot closeModal={closeModal}>
        <DialogHeader>Power profiles</DialogHeader>
        <DialogBody>{error ?? "Loading…"}</DialogBody>
      </ModalRoot>
    );
  }

  const profile = { ...config.profiles[name], ...draft };
  const changed = config.panel.includes(`profile.${name}`);

  return (
    <ModalRoot closeModal={closeModal}>
      <DialogHeader>Power profiles</DialogHeader>
      <DialogBody>
        <DropdownItem
          label="Profile"
          rgOptions={Object.entries(config.profiles).map(([key, p]) => ({ data: key, label: p.label || key }))}
          selectedOption={name}
          onChange={(opt) => setName(opt.data as string)}
        />
        {config.hasCpuFreq && config.governors.length > 0 && (
          <DropdownItem
            label="CPU governor"
            rgOptions={config.governors.map((g) => ({ data: g, label: g }))}
            selectedOption={profile.governor}
            onChange={(opt) => write("governor", opt.data as string, false)}
          />
        )}
        {config.hasCpuFreq && config.clamps.length > 1 && (
          <DropdownItem
            label="CPU clamp table"
            description="Measured per-cluster ceilings for this SoC"
            rgOptions={config.clamps.map((c) => ({ data: c, label: c === "none" ? "None" : c }))}
            selectedOption={profile.cpu_clamp || "none"}
            onChange={(opt) => write("cpu_clamp", opt.data as string, false)}
          />
        )}
        {config.hasCpuFreq && (
          <SliderField
            label="CPU max"
            description={
              profile.cpu_clamp && profile.cpu_clamp !== "none" && config.clamps.includes(profile.cpu_clamp)
                ? "Not used while a clamp table sets the ceiling"
                : "Share of each cluster's top clock"
            }
            value={ratioPercent(profile.cpu_max)}
            min={10}
            max={100}
            step={5}
            showValue
            valueSuffix="%"
            onChange={(v) => write("cpu_max", (v / 100).toFixed(2), true)}
          />
        )}
        {config.hasGpu && (
          <>
            <SliderField
              label="GPU min"
              value={ratioPercent(profile.gpu_min)}
              min={0}
              max={100}
              step={5}
              showValue
              valueSuffix="%"
              onChange={(v) => write("gpu_min", (v / 100).toFixed(2), true)}
            />
            <SliderField
              label="GPU max"
              value={ratioPercent(profile.gpu_max)}
              min={0}
              max={100}
              step={5}
              showValue
              valueSuffix="%"
              onChange={(v) => write("gpu_max", (v / 100).toFixed(2), true)}
            />
          </>
        )}
        {config.hasFan && (
          <DropdownItem
            label="Fan curve"
            rgOptions={Object.keys(config.fanCurves).map((c) => ({ data: c, label: c }))}
            selectedOption={profile.fan_curve}
            onChange={(opt) => write("fan_curve", opt.data as string, false)}
          />
        )}
        {error && <Note error>{error}</Note>}
        {changed && (
          <Row>
            <DialogButton onClick={async () => void apply(await resetPowerConfig(`profile.${name}`))}>
              Reset {profile.label || name} to factory
            </DialogButton>
          </Row>
        )}
      </DialogBody>
      <DialogFooter>
        <DialogButton onClick={closeModal}>Close</DialogButton>
      </DialogFooter>
    </ModalRoot>
  );
}

const coldestFirst = (points: CurvePoint[]) => [...points].sort((a, b) => a[0] - b[0]);

const withPointAdded = (points: CurvePoint[]): CurvePoint[] => {
  let gap = 0;
  for (let i = 1; i < points.length; i++) {
    if (points[i][0] - points[i - 1][0] > points[gap + 1][0] - points[gap][0]) gap = i - 1;
  }
  const [low, high] = [points[gap], points[gap + 1]];
  if (high[0] - low[0] < 2) return points;
  const added: CurvePoint = [Math.round((low[0] + high[0]) / 2), Math.round((low[1] + high[1]) / 2)];
  return coldestFirst([...points, added]);
};

const freeCurveName = (curves: Record<string, unknown>) => {
  for (let n = 1; ; n++) {
    const name = `custom${n}`;
    if (!(name in curves)) return name;
  }
};

function FanEditor({ closeModal, initial, onChanged }: {
  closeModal?: () => void;
  initial: string;
  onChanged: () => void;
}) {
  const { config, error, setError, load } = usePowerConfig();
  const [name, setName] = useState(initial);
  const [points, setPoints] = useState<CurvePoint[] | null>(null);
  const [fanDraft, setFanDraft] = useState<Partial<FanSettings>>({});
  const [resync, setResync] = useState(0);
  const debounce = useDebounced();

  useEffect(() => {
    if (config?.fanCurves[name]) setPoints(coldestFirst(config.fanCurves[name]));
  }, [name, resync, config === null]);

  const apply = async (reply: WriteReply) => {
    setError(reply.ok ? null : reply.error || "write failed");
    await load();
    onChanged();
    return reply.ok;
  };

  if (!config || !points) {
    return (
      <ModalRoot closeModal={closeModal}>
        <DialogHeader>Fan curves</DialogHeader>
        <DialogBody>{error ?? "Loading…"}</DialogBody>
      </ModalRoot>
    );
  }

  const saved = coldestFirst(config.fanCurves[name] ?? []);
  const dirty = JSON.stringify(saved) !== JSON.stringify(points);
  const factory = name in config.factory.fanCurves;
  const users = config.fanCurveUsers[name] ?? [];
  const fan = { ...config.fan, ...fanDraft };
  const maxPoints = config.limits.curvePoints;

  const setPoint = (index: number, point: CurvePoint) =>
    setPoints(points.map((p, i) => (i === index ? point : p)));

  const saveCurve = async (target: string) => {
    const text = [...points].reverse().map(([t, p]) => `${t}:${p}`).join(",");
    if (await apply(await setPowerConfig(`fan_curve.${target}`, { points: text }))) setName(target);
  };

  const writeFan = (key: keyof FanSettings, value: number, delayed = true) => {
    setFanDraft((d) => ({ ...d, [key]: value }));
    const send = async () => {
      await apply(await setPowerConfig("fan", { [key]: String(value) }));
      setFanDraft((d) => {
        const rest = { ...d };
        delete rest[key];
        return rest;
      });
    };
    if (delayed) debounce(key, () => void send());
    else void send();
  };

  return (
    <ModalRoot closeModal={closeModal}>
      <DialogHeader>Fan curves</DialogHeader>
      <DialogBody>
        <DropdownItem
          label="Curve"
          description={users.length ? `Used by: ${users.join(", ")}` : "Not used by any profile"}
          rgOptions={Object.keys(config.fanCurves).map((c) => ({ data: c, label: c }))}
          selectedOption={name}
          disabled={dirty}
          onChange={(opt) => {
            setName(opt.data as string);
            setPoints(coldestFirst(config.fanCurves[opt.data as string]));
          }}
        />
        {points.map(([temp, pwm], i) => (
          <div key={i}>
            {temp === 0 && i === 0 ? null : (
              <SliderField
                label={`Point ${i}`}
                value={temp}
                min={1}
                max={120}
                step={1}
                showValue
                valueSuffix=" °C"
                onChange={(v) => setPoint(i, [v, pwm])}
              />
            )}
            <SliderField
              label={temp === 0 && i === 0 ? "Fan speed when cold" : "Fan speed"}
              value={pwmToPercent(pwm)}
              min={0}
              max={100}
              step={1}
              showValue
              valueSuffix="%"
              onChange={(v) => setPoint(i, [temp, percentToPwm(v)])}
            />
          </div>
        ))}
        <Row>
          <DialogButton disabled={points.length >= maxPoints} onClick={() => setPoints(withPointAdded(points))}>
            Add point
          </DialogButton>
          <DialogButton disabled={points.length <= 2} onClick={() => setPoints(points.slice(0, -1))}>
            Remove hottest
          </DialogButton>
        </Row>
        <Row>
          <DialogButton disabled={!dirty} onClick={() => void saveCurve(name)}>
            Save
          </DialogButton>
          <DialogButton disabled={!dirty} onClick={() => setPoints(saved)}>
            Revert
          </DialogButton>
          <DialogButton onClick={() => void saveCurve(freeCurveName(config.fanCurves))}>Save as new</DialogButton>
        </Row>
        {config.panel.includes(`fan_curve.${name}`) && (
          <Row>
            <DialogButton
              disabled={!factory && users.length > 0}
              onClick={async () => {
                if (!(await apply(await resetPowerConfig(`fan_curve.${name}`)))) return;
                if (factory) setResync((n) => n + 1);
                else setName(initial !== name && initial in config.fanCurves ? initial : Object.keys(config.factory.fanCurves)[0]);
              }}
            >
              {factory ? "Reset curve to factory" : "Delete curve"}
            </DialogButton>
          </Row>
        )}

        <DialogHeader>Fan behaviour</DialogHeader>
        <SliderField
          label="Minimum speed"
          description="Lowest speed while the fan runs"
          value={pwmToPercent(fan.min_pwm)}
          min={0}
          max={100}
          step={1}
          showValue
          valueSuffix="%"
          onChange={(v) => writeFan("min_pwm", percentToPwm(v))}
        />
        <ToggleField
          label="Fan stop"
          description="Switch the fan off when the device is cool"
          checked={fan.stop_below > 0}
          onChange={(on) => writeFan("stop_below", on ? 45 : 0, false)}
        />
        {fan.stop_below > 0 && (
          <>
            <SliderField
              label="Stop below"
              description="Restarts 3 °C above this"
              value={fan.stop_below}
              min={30}
              max={80}
              step={1}
              showValue
              valueSuffix=" °C"
              onChange={(v) => writeFan("stop_below", v)}
            />
            <SliderField
              label="Start speed"
              description="Speed a stopped fan starts at"
              value={pwmToPercent(fan.start_pwm)}
              min={0}
              max={100}
              step={1}
              showValue
              valueSuffix="%"
              onChange={(v) => writeFan("start_pwm", percentToPwm(v))}
            />
          </>
        )}
        <SliderField
          label="Minimum while charging"
          description={fan.charging_min_pwm ? "Also overrides fan stop" : "Off"}
          value={pwmToPercent(fan.charging_min_pwm)}
          min={0}
          max={100}
          step={1}
          showValue
          valueSuffix="%"
          onChange={(v) => writeFan("charging_min_pwm", percentToPwm(v))}
        />
        <SliderField
          label="Ramp up"
          description="Largest speed increase per ~2 s tick"
          value={pwmToPercent(fan.ramp_up)}
          min={1}
          max={100}
          step={1}
          showValue
          valueSuffix="%"
          onChange={(v) => writeFan("ramp_up", Math.max(1, percentToPwm(v)))}
        />
        <SliderField
          label="Ramp down"
          description="Largest speed decrease per ~2 s tick"
          value={pwmToPercent(fan.ramp_down)}
          min={1}
          max={100}
          step={1}
          showValue
          valueSuffix="%"
          onChange={(v) => writeFan("ramp_down", Math.max(1, percentToPwm(v)))}
        />
        <SliderField
          label="Temperature smoothing"
          description="How much of each new reading counts; lower is smoother"
          value={Math.round(fan.smoothing * 100)}
          min={5}
          max={100}
          step={5}
          showValue
          valueSuffix="%"
          onChange={(v) => writeFan("smoothing", v / 100)}
        />
        {config.panel.includes("fan") && (
          <Row>
            <DialogButton onClick={async () => void apply(await resetPowerConfig("fan"))}>
              Reset fan behaviour to factory
            </DialogButton>
          </Row>
        )}
        {error && <Note error>{error}</Note>}
      </DialogBody>
      <DialogFooter>
        <DialogButton onClick={closeModal}>{dirty ? "Close without saving" : "Close"}</DialogButton>
      </DialogFooter>
    </ModalRoot>
  );
}

export function PowerTuning({ profile, fanCurve, onChanged }: {
  profile: string;
  fanCurve: string;
  onChanged: () => void;
}) {
  const { config, error, setError, load } = usePowerConfig();

  if (!config) {
    return error ? (
      <PanelSectionRow>
        <Note error>{error}</Note>
      </PanelSectionRow>
    ) : null;
  }

  const setGamescope = async (values: Record<string, string>) => {
    const reply = await setPowerConfig("gamescope", values);
    setError(reply.ok ? null : reply.error || "write failed");
    await load();
  };

  const edited = () => {
    void load();
    onChanged();
  };

  return (
    <>
      <PanelSectionRow>
        <ButtonItem
          layout="below"
          onClick={() => showModal(<ProfileEditor initial={profile} onChanged={edited} />)}
        >
          Edit power profiles
        </ButtonItem>
      </PanelSectionRow>
      {config.hasFan && (
        <PanelSectionRow>
          <ButtonItem
            layout="below"
            onClick={() => showModal(<FanEditor initial={fanCurve} onChanged={edited} />)}
          >
            Edit fan curves
          </ButtonItem>
        </PanelSectionRow>
      )}
      <PanelSectionRow>
        <DropdownItem
          label="gamescope priority"
          description="CPU priority of the compositor, not inherited by games"
          rgOptions={GAMESCOPE_PRIORITIES}
          selectedOption={nearest(GAMESCOPE_PRIORITIES, config.gamescope.nice)}
          onChange={(opt) => void setGamescope({ nice: String(opt.data) })}
        />
      </PanelSectionRow>
      <PanelSectionRow>
        <ToggleField
          label="Realtime GPU queue for gamescope"
          description="From the next session start. Lets gamescope preempt the game on the GPU; can cause glitches on turnip."
          checked={config.gamescope.vulkan_realtime}
          onChange={(on) => void setGamescope({ vulkan_realtime: on ? "true" : "false" })}
        />
      </PanelSectionRow>
      {error && (
        <PanelSectionRow>
          <Note error>{error}</Note>
        </PanelSectionRow>
      )}
    </>
  );
}
