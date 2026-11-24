import {
  ABI_VERSION, COMMAND_CAPACITY, PARAM_CAPACITY,
  beginFrame, closePath, commandsPointer, finishFrame, getParam,
  lineTo, moveTo, paramsPointer, style,
} from "../sdk/abi";

const VERTICES: StaticArray<f32> = [
  -1, -1, -1,  1, -1, -1,  1,  1, -1, -1,  1, -1,
  -1, -1,  1,  1, -1,  1,  1,  1,  1, -1,  1,  1,
];
const EDGES: StaticArray<i32> = [
  0, 1, 1, 2, 2, 3, 3, 0,
  4, 5, 5, 6, 6, 7, 7, 4,
  0, 4, 1, 5, 2, 6, 3, 7,
];
const projected = new StaticArray<f32>(16);

export function abi_version(): i32 { return ABI_VERSION; }
export function params_ptr(): usize { return paramsPointer(); }
export function params_capacity(): i32 { return PARAM_CAPACITY; }
export function commands_ptr(): usize { return commandsPointer(); }
export function commands_capacity(): i32 { return COMMAND_CAPACITY; }

export function render(time: f64, _beat: f64): i32 {
  beginFrame();
  const master = getParam(0);
  const ax = <f32>time * master * getParam(1) + getParam(12);
  const ay = <f32>time * master * getParam(2) + getParam(13);
  const az = <f32>time * master * getParam(3) + getParam(14);
  const perspective = getParam(4) >= 0.5;
  const size = getParam(5);
  const aspectScale = getParam(11);

  const cx = Mathf.cos(ax), sx = Mathf.sin(ax);
  const cy = Mathf.cos(ay), sy = Mathf.sin(ay);
  const cz = Mathf.cos(az), sz = Mathf.sin(az);

  for (let i = 0; i < 8; i++) {
    const o = i * 3;
    const x = unchecked(VERTICES[o]);
    const y = unchecked(VERTICES[o + 1]);
    const z = unchecked(VERTICES[o + 2]);

    // Use Rz * Ry * Rx rotation order.
    const x1 = x;
    const y1 = y * cx - z * sx;
    const z1 = y * sx + z * cx;
    const x2 = x1 * cy + z1 * sy;
    const y2 = y1;
    const z2 = -x1 * sy + z1 * cy;
    const x3 = x2 * cz - y2 * sz;
    const y3 = x2 * sz + y2 * cz;
    const fac: f32 = perspective
      ? <f32>3.0 / (z2 + <f32>4.5) : <f32>1.0;
    const scale: f32 = (perspective ? <f32>0.28 : <f32>0.21) * size;
    unchecked(projected[i * 2] =
      <f32>0.5 + x3 * fac * scale * aspectScale);
    unchecked(projected[i * 2 + 1] =
      <f32>0.5 + y3 * fac * scale);
  }

  style(
    1, 1, 1, 1,
    getParam(6), getParam(7), getParam(8), 0.82,
    getParam(9), getParam(10),
  );
  for (let edge = 0; edge < 12; edge++) {
    const a = unchecked(EDGES[edge * 2]);
    const b = unchecked(EDGES[edge * 2 + 1]);
    moveTo(unchecked(projected[a * 2]), unchecked(projected[a * 2 + 1]));
    lineTo(unchecked(projected[b * 2]), unchecked(projected[b * 2 + 1]));
  }
  return finishFrame();
}
