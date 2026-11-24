import {
  ABI_VERSION, COMMAND_CAPACITY, PARAM_CAPACITY,
  beginFrame, commandsPointer, finishFrame, getParam,
  lineTo, moveTo, paramsPointer, style,
} from "../sdk/abi";
import { TAU, clamp01, hash2, mix } from "../sdk/math";

const COLUMNS = 10;
const ROWS = 128;
const HISTORY = 24;
const coreCells = new StaticArray<f32>(ROWS);
const flowCells = new StaticArray<f32>(ROWS);

export function abi_version(): i32 { return ABI_VERSION; }
export function params_ptr(): usize { return paramsPointer(); }
export function params_capacity(): i32 { return PARAM_CAPACITY; }
export function commands_ptr(): usize { return commandsPointer(); }
export function commands_capacity(): i32 { return COMMAND_CAPACITY; }

function pulseStart(event: i32, column: i32, rate: f32, burst: f32): f32 {
  const spacing = <f32>1.0 / rate;
  return <f32>event * spacing
    + (hash2(column, event * 17 + 31) - <f32>0.5)
      * spacing * <f32>0.5 * burst;
}

function applyPulse(
  column: i32, event: i32, salt: i32, now: f32, rate: f32,
  speed: f32, jitter: f32, length: f32, decay: f32,
  delay: f32, amplitudeScale: f32, burst: f32,
): void {
  const age = now - pulseStart(event, column, rate, burst) - delay;
  if (age < 0) return;
  const velocity = Mathf.max(
    <f32>0.02,
    speed * mix(
      <f32>1.0 - jitter * <f32>0.65,
      <f32>1.0 + jitter * <f32>1.2,
      hash2(column, event * 23 + 47, salt)));
  const position = age * velocity;
  if (position > <f32>1.25) return;

  const amplitude = amplitudeScale
    * mix(<f32>1.0 - burst * <f32>0.3, <f32>1.0 + burst * <f32>0.25, hash2(column, event * 29 + 59, salt))
    * Mathf.exp(-Mathf.max(<f32>0.0, position - <f32>0.15) * <f32>0.22);
  const width = Mathf.max(
    <f32>0.002,
    length * mix(
      <f32>1.0 - jitter * <f32>0.35, <f32>1.0 + jitter * <f32>0.35, hash2(column, event * 31 + 71, salt)));
  const sigma = Mathf.max(width * <f32>0.22, <f32>0.0005);

  for (let row = 0; row < ROWS; row++) {
    const sample = (<f32>row + <f32>0.5) / <f32>ROWS;
    const distance = sample - position;
    const head = Mathf.exp(
      <f32>-0.5 * (distance / sigma) * (distance / sigma));
    const back = distance <= 0
      ? clamp01(<f32>1.0 + distance / width)
      : <f32>0.0;
    const passedFor = age - sample / velocity;
    const afterglow = passedFor >= 0
      ? Mathf.exp(-passedFor * decay) * amplitude
      : <f32>0.0;
    const core = head * amplitude;
    const flow = Mathf.max(
      (head * <f32>0.55 + back * <f32>0.75) * amplitude,
      afterglow * <f32>0.55);
    if (core > unchecked(coreCells[row])) {
      unchecked(coreCells[row] = core);
    }
    if (flow > unchecked(flowCells[row])) {
      unchecked(flowCells[row] = flow);
    }
  }
}

function applySpark(position: f32, gain: f32, width: f32): void {
  const sigma = Mathf.max(width, <f32>0.0005);
  for (let row = 0; row < ROWS; row++) {
    const sample = (<f32>row + <f32>0.5) / <f32>ROWS;
    const distance = sample - position;
    const flash = Mathf.exp(
      <f32>-0.5 * (distance / sigma) * (distance / sigma)) * gain;
    if (flash > unchecked(flowCells[row])) {
      unchecked(flowCells[row] = flash);
    }
  }
}

function paletteChannel(hue: f32, shift: f32): f32 {
  return <f32>0.5 + <f32>0.5 * Mathf.cos(TAU * (hue - shift));
}

export function render(time: f64, _beat: f64): i32 {
  beginFrame();
  const rate = Mathf.max(<f32>0.0, getParam(0));
  const burst = clamp01(getParam(1));
  const speed = Mathf.max(<f32>0.05, getParam(2));
  const jitter = clamp01(getParam(3));
  const length = getParam(4);
  const tail = clamp01(getParam(5));
  const crackle = clamp01(getParam(6));
  const forks = clamp01(getParam(7));
  const topSpray = clamp01(getParam(8));
  const brightness = getParam(9);
  const coreR = getParam(10), coreG = getParam(11), coreB = getParam(12);
  const glowR = getParam(13), glowG = getParam(14), glowB = getParam(15);
  const rainbow = clamp01(getParam(16));
  const reverse = getParam(17) >= <f32>0.5;
  const now = <f32>time;
  if (rate <= 0 || brightness <= 0) return finishFrame();

  const decay = <f32>2.0 + (<f32>1.0 - tail) * <f32>22.0;
  const frame = <i32>Mathf.floor(now * <f32>30.0);
  const cellHeight = <f32>0.78 / <f32>ROWS;
  const columnWidth = <f32>1.0 / <f32>COLUMNS;
  const columnInset = columnWidth * <f32>0.045;

  for (let column = 0; column < COLUMNS; column++) {
    for (let row = 0; row < ROWS; row++) {
      unchecked(coreCells[row] = 0);
      unchecked(flowCells[row] = 0);
    }

    const offset = hash2(column, 5) * burst / rate;
    const localNow = now + offset;
    const currentEvent = <i32>Mathf.floor(localNow * rate);
    for (let previous = 0; previous < HISTORY; previous++) {
      const event = currentEvent - previous;
      applyPulse(
        column, event, 0, localNow, rate, speed, jitter,
        length, decay, 0, 1, burst);

      const childChance = clamp01(
        burst * <f32>0.55 + forks * <f32>0.35);
      if (hash2(column, event * 41 + 83) < childChance) {
        const childDelay = mix(
          <f32>0.06, <f32>0.32, hash2(column, event * 43 + 89));
        const childGain = mix(
          <f32>0.25, <f32>0.55, hash2(column, event * 47 + 97));
        applyPulse(
          column, event, 101, localNow, rate, speed, jitter,
          length * <f32>0.62, decay, childDelay, childGain, burst);
      }

      const start = pulseStart(event, column, rate, burst);
      if (topSpray > 0
          && hash2(column, event * 53 + 107) < topSpray * <f32>0.7) {
        const ttl = mix(
          <f32>0.025, <f32>0.12, hash2(column, event * 59 + 109));
        const sprayAge = localNow - start
          - hash2(column, event * 61 + 113) * <f32>0.3;
        if (sprayAge >= 0 && sprayAge < ttl) {
          const randomPosition = hash2(column, event * 67 + 127);
          const position = randomPosition * randomPosition * randomPosition
            * (<f32>0.05 + <f32>0.28 * topSpray);
          applySpark(
            position,
            (<f32>1.0 - sprayAge / ttl)
              * mix(<f32>0.35, <f32>1.0,
                hash2(column, event * 71 + 131)),
            mix(<f32>0.002, <f32>0.012 + <f32>0.025 * crackle,
              hash2(column, event * 73 + 137)));
        }
      }

      if (forks > 0
          && hash2(column, event * 79 + 139) < forks) {
        const forkDelay = mix(
          <f32>0.12, <f32>1.05, hash2(column, event * 83 + 149));
        const ttl = mix(
          <f32>0.025, <f32>0.12, hash2(column, event * 89 + 151));
        const forkAge = localNow - start - forkDelay;
        if (forkAge >= 0 && forkAge < ttl) {
          const position = clamp01(
            forkDelay * speed
              + (hash2(column, event * 97 + 157) - <f32>0.5)
                * (<f32>0.015 + <f32>0.16 * crackle));
          applySpark(
            position,
            (<f32>1.0 - forkAge / ttl)
              * mix(<f32>0.35, <f32>1.0,
                hash2(column, event * 101 + 163)),
            mix(<f32>0.002, <f32>0.012 + <f32>0.025 * crackle,
              hash2(column, event * 103 + 167)));
        }
      }
    }

    const x0 = <f32>column * columnWidth + columnInset;
    const x1 = <f32>(column + 1) * columnWidth - columnInset;
    for (let outputRow = 0; outputRow < ROWS; outputRow++) {
      const sourceRow = reverse ? ROWS - outputRow - 1 : outputRow;
      const sample = (<f32>sourceRow + <f32>0.5) / <f32>ROWS;
      const noiseCell = sourceRow / 5;
      const noiseAmount = mix(
        <f32>1.0 - crackle * <f32>0.9,
        <f32>1.0,
        hash2(column * 257 + noiseCell, frame));
      const core = Mathf.min(
        <f32>1.4,
        unchecked(coreCells[sourceRow])
          * mix(<f32>1.0 - crackle * <f32>0.15, <f32>1.0 + crackle * <f32>0.15,
            hash2(column * ROWS + sourceRow, frame + 173)));
      const flow = Mathf.min(
        <f32>1.2, unchecked(flowCells[sourceRow]) * noiseAmount);
      const hue = sample + now * <f32>0.09;
      const ionR = paletteChannel(hue, 0);
      const ionG = paletteChannel(hue, <f32>0.3333333);
      const ionB = paletteChannel(hue, <f32>0.6666667);
      const mixedGlowR = mix(glowR, ionR, rainbow);
      const mixedGlowG = mix(glowG, ionG, rainbow);
      const mixedGlowB = mix(glowB, ionB, rainbow);
      const red = clamp01((mixedGlowR * flow + coreR * core) * brightness);
      const green = clamp01(
        (mixedGlowG * flow + coreG * core) * brightness);
      const blue = clamp01(
        (mixedGlowB * flow + coreB * core) * brightness);
      if (Mathf.max(red, Mathf.max(green, blue)) < <f32>0.004) continue;

      // A cell is a flat, hard-edged RGB rectangle. "Glow" above only affects
      // its color/brightness, exactly like the pixelated LED web monitor.
      style(red, green, blue, 1, 0, 0, 0, 0, cellHeight, 0);
      const y = (<f32>outputRow + <f32>0.5) / <f32>ROWS;
      moveTo(x0, y);
      lineTo(x1, y);
    }
  }
  return finishFrame();
}
