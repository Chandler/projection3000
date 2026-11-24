// Vibe Vector ABI 1. All coordinates and stroke sizes are normalized to the
// content height. The host applies projector mapping before rasterization.

export const ABI_VERSION: i32 = 1;
export const PARAM_CAPACITY: i32 = 64;
export const COMMAND_CAPACITY: i32 = 65536;

export const OP_STYLE: f32 = 1.0;
export const OP_MOVE: f32 = 2.0;
export const OP_LINE: f32 = 3.0;
export const OP_CLOSE: f32 = 4.0;

export const params = new StaticArray<f32>(PARAM_CAPACITY);
export const commands = new StaticArray<f32>(COMMAND_CAPACITY);
let cursor: i32 = 0;

export function getParam(index: i32): f32 {
  return unchecked(params[index]);
}

function push(value: f32): void {
  unchecked(commands[cursor] = value);
  cursor += 1;
}

export function beginFrame(): void {
  cursor = 0;
}

export function style(
  coreR: f32, coreG: f32, coreB: f32, coreA: f32,
  glowR: f32, glowG: f32, glowB: f32, glowA: f32,
  coreWidth: f32, glowWidth: f32,
): void {
  push(OP_STYLE);
  push(coreR); push(coreG); push(coreB); push(coreA);
  push(glowR); push(glowG); push(glowB); push(glowA);
  push(coreWidth); push(glowWidth);
}

export function moveTo(x: f32, y: f32): void {
  push(OP_MOVE); push(x); push(y);
}

export function lineTo(x: f32, y: f32): void {
  push(OP_LINE); push(x); push(y);
}

export function closePath(): void {
  push(OP_CLOSE);
}

export function finishFrame(): i32 {
  return cursor;
}

export function paramsPointer(): usize {
  return changetype<usize>(params);
}

export function commandsPointer(): usize {
  return changetype<usize>(commands);
}
