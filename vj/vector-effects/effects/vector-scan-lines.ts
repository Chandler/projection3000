import {
  ABI_VERSION, COMMAND_CAPACITY, PARAM_CAPACITY,
  beginFrame, commandsPointer, finishFrame, getParam,
  lineTo, moveTo, paramsPointer, style,
} from "../sdk/abi";
import { TAU, fract } from "../sdk/math";

export function abi_version(): i32 { return ABI_VERSION; }
export function params_ptr(): usize { return paramsPointer(); }
export function params_capacity(): i32 { return PARAM_CAPACITY; }
export function commands_ptr(): usize { return commandsPointer(); }
export function commands_capacity(): i32 { return COMMAND_CAPACITY; }

export function render(time: f64, beat: f64): i32 {
  beginFrame();
  const angle = getParam(0);
  const rate = getParam(1);
  const spacing = Mathf.max(<f32>0.008, getParam(2));
  const coreWidth = getParam(3);
  const glowWidth = getParam(4);
  const amount = getParam(5);
  const wave = getParam(6);
  const waveFrequency = getParam(7);
  const beatPulse = getParam(8);
  const coreR = getParam(9), coreG = getParam(10), coreB = getParam(11);
  const glowR = getParam(12), glowG = getParam(13), glowB = getParam(14);
  const aspect = getParam(15);

  const tx = Mathf.cos(angle) * aspect;
  const ty = Mathf.sin(angle);
  const nx = -Mathf.sin(angle) * aspect;
  const ny = Mathf.cos(angle);
  const span: f32 = 2.8;
  const count = <i32>Mathf.min(240, Mathf.ceil(span / spacing) + 2);
  const offset = fract(<f32>time * rate / spacing) * spacing;
  const beatEnvelope = Mathf.exp(
    -fract(<f32>beat) * <f32>5.0);
  const gain = amount * (<f32>1.0 + beatPulse * beatEnvelope);

  for (let line = 0; line < count; line++) {
    const normal = -span * <f32>0.5 + <f32>line * spacing + offset;
    const alternating = <f32>0.72 + <f32>0.28
      * Mathf.sin(<f32>line * <f32>1.618 + <f32>time * <f32>0.7);
    style(
      coreR, coreG, coreB, gain * alternating,
      glowR, glowG, glowB, gain * alternating * <f32>0.78,
      coreWidth, glowWidth,
    );
    const points = wave > 0 ? 18 : 1;
    for (let point = 0; point <= points; point++) {
      const along = -span * <f32>0.5
        + span * <f32>point / <f32>points;
      const bend = wave * Mathf.sin(
        along * waveFrequency * TAU
        + <f32>time * rate * <f32>4.0 + <f32>line * <f32>0.37);
      const x = <f32>0.5 + tx * along + nx * (normal + bend);
      const y = <f32>0.5 + ty * along + ny * (normal + bend);
      if (point == 0) moveTo(x, y);
      else lineTo(x, y);
    }
  }
  return finishFrame();
}
