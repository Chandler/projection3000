// Vibe Graphics ABI 2. V2 retains the v1 module boundary while adding
// attributed vertices, cubic Bézier paths, and Gaussian point splats.

export const ABI_VERSION: i32 = 2;
export const PARAM_CAPACITY: i32 = 64;
export const COMMAND_CAPACITY: i32 = 65536;

export const OP_VERTEX_MOVE: f32 = 5.0;
export const OP_VERTEX_LINE: f32 = 6.0;
export const OP_VERTEX_CUBIC: f32 = 7.0;
export const OP_SPLAT: f32 = 8.0;

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

function pushVertex(
  x: f32, y: f32,
  coreR: f32, coreG: f32, coreB: f32, coreA: f32,
  glowR: f32, glowG: f32, glowB: f32, glowA: f32,
  coreWidth: f32, glowWidth: f32,
): void {
  push(x); push(y);
  push(coreR); push(coreG); push(coreB); push(coreA);
  push(glowR); push(glowG); push(glowB); push(glowA);
  push(coreWidth); push(glowWidth);
}

export function beginFrame(): void {
  cursor = 0;
}

export function moveVertex(
  x: f32, y: f32,
  coreR: f32, coreG: f32, coreB: f32, coreA: f32,
  glowR: f32, glowG: f32, glowB: f32, glowA: f32,
  coreWidth: f32, glowWidth: f32,
): void {
  push(OP_VERTEX_MOVE);
  pushVertex(
    x, y, coreR, coreG, coreB, coreA,
    glowR, glowG, glowB, glowA, coreWidth, glowWidth);
}

export function lineVertex(
  x: f32, y: f32,
  coreR: f32, coreG: f32, coreB: f32, coreA: f32,
  glowR: f32, glowG: f32, glowB: f32, glowA: f32,
  coreWidth: f32, glowWidth: f32,
): void {
  push(OP_VERTEX_LINE);
  pushVertex(
    x, y, coreR, coreG, coreB, coreA,
    glowR, glowG, glowB, glowA, coreWidth, glowWidth);
}

export function cubicVertex(
  control1X: f32, control1Y: f32,
  control2X: f32, control2Y: f32,
  x: f32, y: f32,
  coreR: f32, coreG: f32, coreB: f32, coreA: f32,
  glowR: f32, glowG: f32, glowB: f32, glowA: f32,
  coreWidth: f32, glowWidth: f32,
): void {
  push(OP_VERTEX_CUBIC);
  push(control1X); push(control1Y);
  push(control2X); push(control2Y);
  pushVertex(
    x, y, coreR, coreG, coreB, coreA,
    glowR, glowG, glowB, glowA, coreWidth, glowWidth);
}

export function splat(
  x: f32, y: f32,
  coreR: f32, coreG: f32, coreB: f32, coreA: f32,
  glowR: f32, glowG: f32, glowB: f32, glowA: f32,
  coreDiameter: f32, glowRadius: f32,
): void {
  push(OP_SPLAT);
  pushVertex(
    x, y, coreR, coreG, coreB, coreA,
    glowR, glowG, glowB, glowA, coreDiameter, glowRadius);
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
