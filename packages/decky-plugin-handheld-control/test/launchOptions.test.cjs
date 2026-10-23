const assert = require("assert");
const { readTweaks, writeTweaks, hasStaleFrameCap } = require("./launchOptions.js");
let n = 0;
const check = (name, got, want) => { assert.strictEqual(got, want, name); n++; };
const set = (opts, change) => writeTweaks(opts, { ...readTweaks(opts), ...change });

// reading
check("plain wrapper reads as devel", readTweaks("turnip-devel %command%").turnip, "devel");
check("perf wrapper reads as perf", readTweaks("turnip-perf %command%").turnip, "perf");
check("no wrapper reads as stable", readTweaks("PROTON_LOG=1 %command%").turnip, "");
check("wrapper after env and pin", readTweaks("TU_SAFE_PREEMPT=1 taskset -c 4-7 turnip-devel %command%").turnip, "devel");

// writing
check("stable -> devel", set("%command%", { turnip: "devel" }), "turnip-devel %command%");
check("devel -> stable empties", set("turnip-devel %command%", { turnip: "" }), "");
check("devel -> perf", set("turnip-devel %command%", { turnip: "perf" }), "turnip-perf %command%");
check("env stays before the wrapper", set("PROTON_LOG=1 %command%", { turnip: "devel" }), "PROTON_LOG=1 turnip-devel %command%");
check("wrapper after the core pin", set("taskset -c 4-7 %command%", { turnip: "devel" }), "taskset -c 4-7 turnip-devel %command%");
check("other commands kept after the wrapper", set("gamemoderun %command% -dx12", { turnip: "devel" }), "turnip-devel gamemoderun %command% -dx12");

// other tweaks leave the wrapper alone
check("frame gen tweak keeps devel", set("turnip-devel %command%", { flags: { ...readTweaks("turnip-devel %command%").flags, safePreempt: true } }), "TU_SAFE_PREEMPT=1 turnip-devel %command%");
check("round trip is stable", set("TU_SAFE_PREEMPT=1 taskset -c 4-7 turnip-devel %command% -foo", {}), "TU_SAFE_PREEMPT=1 taskset -c 4-7 turnip-devel %command% -foo");
check("unknown key falls back to no wrapper", set("%command%", { turnip: "bogus" }), "");

// the frame-gen base cap reaches DXVK, vkd3d-proton and native Vulkan alike
const capped = 'DXVK_CONFIG="dxgi.maxFrameRate=31;d3d9.maxFrameRate=31" VKD3D_FRAME_RATE=31 MANGOHUD_PROBE_FPS_LIMIT=31 %command%';
check("a cap writes all three limiters", set("%command%", { frameCap: 31 }), capped);
check("a probe-only cap reads back", readTweaks("MANGOHUD_PROBE_FPS_LIMIT=31 %command%").frameCap, 31);
check("removing the cap removes all three", set(capped, { frameCap: 0 }), "");
check("a cap from before the probe is stale", hasStaleFrameCap('DXVK_CONFIG="dxgi.maxFrameRate=31;d3d9.maxFrameRate=31" VKD3D_FRAME_RATE=31 %command%'), true);
check("a current cap is not stale", hasStaleFrameCap(capped), false);
check("cap and driver together", set("turnip-devel %command%", { frameCap: 31 }), capped.replace("%command%", "turnip-devel %command%"));
console.log(`${n} checks passed`);
