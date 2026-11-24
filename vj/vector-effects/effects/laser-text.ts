import { ABI_VERSION, COMMAND_CAPACITY, beginFrame, commandsPointer,
  finishFrame, style, moveTo, lineTo } from '../sdk/abi';

// Font outline geometry follows the 13 live controls as (op, x, y) triples.
const data = new StaticArray<f32>(32768);
export function abi_version(): i32 { return ABI_VERSION; }
export function params_ptr(): usize { return changetype<usize>(data); }
export function params_capacity(): i32 { return 32768; }
export function commands_ptr(): usize { return commandsPointer(); }
export function commands_capacity(): i32 { return COMMAND_CAPACITY; }
function p(i: i32): f32 { return unchecked(data[i]); }

export function render(time: f64, beat: f64): i32 {
  beginFrame();
  const count = min(10000, max(0, i32(p(12))));
  let halfWidth: f32 = 0, halfHeight: f32 = 0;
  for (let i = 0; i < count; i++) {
    halfWidth = max(halfWidth, abs(p(14+i*3)));
    halfHeight = max(halfHeight, abs(p(15+i*3)));
  }
  const aspect = max(0.001, p(11));
  const size: f32 = min(p(6), min(f32(0.45)/max(halfWidth*aspect, f32(0.001)),
                                        f32(0.45)/max(halfHeight, f32(0.001))));
  const pulse: f32 = 1.0-p(9)*f32(0.5-0.5*Math.cos(time*p(10)*Math.PI*2));
  const brightness = p(5)*pulse;
  style(0.8+0.2*p(0), 0.8+0.2*p(1), 0.8+0.2*p(2), brightness,
        p(0), p(1), p(2), brightness, p(3), p(4));
  for (let i = 0; i < count; i++) {
    const x = p(7)+p(14+i*3)*size*aspect;
    const y = p(8)+p(15+i*3)*size;
    if (p(13+i*3) == 2) moveTo(x, y);
    else lineTo(x, y);
  }
  return finishFrame();
}
