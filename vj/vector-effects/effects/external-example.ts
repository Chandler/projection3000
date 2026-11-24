import {
  ABI_VERSION, PARAM_CAPACITY, COMMAND_CAPACITY,
  paramsPointer, commandsPointer, beginFrame, finishFrame,
  getParam, style, moveTo, lineTo,
} from "../sdk/abi";

export function abi_version(): i32 { return ABI_VERSION; }
export function params_ptr(): usize { return paramsPointer(); }
export function params_capacity(): i32 { return PARAM_CAPACITY; }
export function commands_ptr(): usize { return commandsPointer(); }
export function commands_capacity(): i32 { return COMMAND_CAPACITY; }

export function render(time: f64, beat: f64): i32 {
  beginFrame();
  const angle = <f32>time * getParam(0);
  const x = Mathf.cos(angle) * <f32>0.3;
  const y = Mathf.sin(angle) * <f32>0.3;
  style(1, 1, 1, 1, 0.2, 0.6, 1, 0.8, 0.004, 0.02);
  moveTo(0.5 - x, 0.5 - y);
  lineTo(0.5 + x, 0.5 + y);
  return finishFrame();
}
