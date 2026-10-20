import { callable } from "@decky/api";

export interface PowerProfile {
  label: string;
  governor: string;
  cpu_clamp: string;
  cpu_max: string;
  gpu_min: string;
  gpu_max: string;
  fan_curve: string;
}

export interface FanSettings {
  min_pwm: number;
  max_pwm: number;
  ramp_up: number;
  ramp_down: number;
  pwm_quantum: number;
  stop_below: number;
  start_pwm: number;
  charging_min_pwm: number;
  smoothing: number;
}

export type CurvePoint = [number, number];

export interface PowerConfig {
  profiles: Record<string, PowerProfile>;
  fanCurves: Record<string, CurvePoint[]>;
  fanCurveUsers: Record<string, string[]>;
  fan: FanSettings;
  gamescope: { nice: number; vulkan_realtime: boolean };
  factory: {
    profiles: Record<string, PowerProfile>;
    fanCurves: Record<string, CurvePoint[]>;
    fan: FanSettings;
  };
  panel: string[];
  governors: string[];
  clamps: string[];
  limits: { curvePoints: number };
  hasFan: boolean;
  hasGpu: boolean;
  hasCpuFreq: boolean;
}

interface ConfigReply { ok: boolean; error?: string; config?: PowerConfig }
export interface WriteReply { ok: boolean; error?: string }
export interface GameTuningReply { ok: boolean; error?: string; nice: number; irq: boolean; cores: string }

export const getPowerConfig = callable<[], ConfigReply>("get_power_config");
export const setPowerConfig = callable<[section: string, values: Record<string, string>], WriteReply>(
  "set_power_config",
);
export const resetPowerConfig = callable<[section: string], WriteReply>("reset_power_config");
export const getGameTuning = callable<[appid: string], GameTuningReply>("get_game_tuning");
export const setGameTuning = callable<[appid: string, nice: number, irq: boolean], WriteReply>("set_game_tuning");

export const pwmToPercent = (pwm: number) => Math.round((pwm / 255) * 100);
export const percentToPwm = (percent: number) => Math.round((percent / 100) * 255);
