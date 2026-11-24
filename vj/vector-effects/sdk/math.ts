export const TAU: f32 = 6.283185307179586;

export function fract(value: f32): f32 {
  return value - Mathf.floor(value);
}

export function clamp01(value: f32): f32 {
  return Mathf.max(0, Mathf.min(1, value));
}

// Integer mixing keeps procedural scenes deterministic and independent of
// evaluation order. That matters because one WASM module instance may serve
// several browser monitors with different parameter snapshots.
export function hash(value: i32): f32 {
  let bits = <u32>value;
  bits ^= bits >> 16;
  bits *= 0x7feb352d;
  bits ^= bits >> 15;
  bits *= 0x846ca68b;
  bits ^= bits >> 16;
  return <f32>(bits & 0x00ffffff) / <f32>0x01000000;
}

export function hash2(a: i32, b: i32, seed: i32 = 0): f32 {
  return hash(a * 0x1f123bb5 + b * 0x05491333 + seed * 0x6d2b79f5);
}

export function mix(a: f32, b: f32, amount: f32): f32 {
  return a + (b - a) * amount;
}
