import {
  ABI_VERSION, COMMAND_CAPACITY, PARAM_CAPACITY,
  beginFrame, commandsPointer, finishFrame, getParam, lineVertex,
  moveVertex, paramsPointer,
} from "../sdk/graphics-v2";
import { TAU, clamp01, fract, hash2 } from "../sdk/math";

export function abi_version(): i32 { return ABI_VERSION; }
export function params_ptr(): usize { return paramsPointer(); }
export function params_capacity(): i32 { return PARAM_CAPACITY; }
export function commands_ptr(): usize { return commandsPointer(); }
export function commands_capacity(): i32 { return COMMAND_CAPACITY; }

export function render(time: f64, _beat: f64): i32 {
  beginFrame();
  const speed = getParam(0);
  const trailLength = clamp01(getParam(1));
  const zoom = getParam(2);
  const rotation = getParam(3);
  const tilt = getParam(4);
  const lineWidth = getParam(5);
  const brightness = getParam(6);
  const red = getParam(7), green = getParam(8), blue = getParam(9);
  const seed = <i32>Mathf.round(getParam(10));
  const aspect = getParam(11);
  const now = <f32>time;

  // A long, deterministic canonical Lorenz orbit. Only a moving window of
  // this trajectory is emitted, so the front advances while the back fades.
  const pathPoints = 2400;
  const visiblePoints = <i32>Mathf.max(
    8, Mathf.min(<f32>pathPoints,
      Mathf.round(trailLength * <f32>pathPoints)));
  let phase = fract(
    now * Mathf.abs(speed) * <f32>0.022 + hash2(seed, 41, 73));
  if (speed < 0) phase = <f32>1.0 - phase;
  // Keep the moving window contiguous inside the deterministic trajectory.
  // That makes the output one path (one move followed by line commands),
  // rather than splitting it when a circular buffer wraps.
  const travelPoints = pathPoints - visiblePoints;
  const head = visiblePoints - 1
    + <i32>Mathf.floor(phase * <f32>(travelPoints + 1));

  const yaw = now * rotation + hash2(seed, 17, 31) * TAU;
  const cosYaw = Mathf.cos(yaw), sinYaw = Mathf.sin(yaw);
  const cosTilt = Mathf.cos(tilt), sinTilt = Mathf.sin(tilt);

  const sigma: f32 = <f32>10.0;
  const rho: f32 = <f32>28.0;
  const beta: f32 = <f32>2.6666667;
  const dt: f32 = <f32>0.006;
  const stride = 2;
  const warmup = 1000 + seed % 97;
  let x: f32 = <f32>0.08 + hash2(seed, 1, 19) * <f32>0.08;
  let y: f32 = <f32>0.01 + hash2(seed, 2, 23) * <f32>0.04;
  let z: f32 = <f32>0.02 + hash2(seed, 3, 29) * <f32>0.03;
  let pointIndex = 0;

  for (let step = 0; step < warmup + pathPoints * stride; step++) {
    // Midpoint integration keeps the numerical orbit smooth without storing
    // or shipping a baked curve.
    const dx = sigma * (y - x);
    const dy = x * (rho - z) - y;
    const dz = x * y - beta * z;
    const mx = x + dx * dt * <f32>0.5;
    const my = y + dy * dt * <f32>0.5;
    const mz = z + dz * dt * <f32>0.5;
    x += sigma * (my - mx) * dt;
    y += (mx * (rho - mz) - my) * dt;
    z += (mx * my - beta * mz) * dt;

    if (step < warmup || (step - warmup) % stride != 0) continue;
    const distanceBehind = head - pointIndex;
    const visible = distanceBehind >= 0 && distanceBehind < visiblePoints;
    if (visible) {
      const horizontal = x * cosYaw - y * sinYaw;
      const yawDepth = x * sinYaw + y * cosYaw;
      const centeredZ = z - rho * <f32>0.9;
      const vertical = centeredZ * cosTilt - yawDepth * sinTilt;
      const px = <f32>0.5 + horizontal * zoom * aspect / <f32>36.0;
      const py = <f32>0.51 - vertical * zoom / <f32>43.0;

      if (distanceBehind == visiblePoints - 1) {
        moveVertex(
          px, py, red, green, blue, brightness,
          red, green, blue, 0,
          lineWidth, 0);
      } else {
        lineVertex(
          px, py, red, green, blue, brightness,
          red, green, blue, 0,
          lineWidth, 0);
      }
    }
    pointIndex++;
  }
  return finishFrame();
}
