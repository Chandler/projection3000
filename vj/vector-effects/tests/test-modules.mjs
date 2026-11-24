import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const modules = [
  {
    file: new URL("../../static/vector/modules/lorenz-attractor.wasm", import.meta.url),
    abi: 2,
    params: [
      0.5, 0.22, 0.9, 0.08, 18 * Math.PI / 180,
      2 / 540, 1, 0.33, 0.92, 1, 7, 540 / 960,
    ],
    minimumSegments: 500,
    expectedMoves: 1,
    expectedSplats: 0,
  },
  {
    file: new URL("../../static/vector/modules/vector-cube.wasm", import.meta.url),
    params: [1, 0, 0.55, 0, 0, 1, 0.1, 0.65, 1, 0.0025, 0.018, 0.5625],
    minimumSegments: 12,
  },
  {
    file: new URL("../../static/vector/modules/electric-strips.wasm", import.meta.url),
    params: [
      0.8, 0.45, 0.55, 0.35, 0.08, 0.62, 0.38, 0.32, 0.45, 1,
      0.97, 0.98, 1, 0.26, 0.66, 1,
      0, 0,
    ],
    minimumSegments: 50,
    horizontalOnly: true,
  },
  {
    file: new URL("../../static/vector/modules/vector-scan-lines.wasm", import.meta.url),
    params: [
      0, 0.2, 0.2, 0.006, 0.026, 0.85, 0.02, 1.5, 0.2,
      0.85, 0.97, 1, 0.21, 0.85, 1, 0.5625,
    ],
    minimumSegments: 10,
  },
  // Exercise UI maxima that can materially grow the ABI command stream. These
  // fixtures catch effects that look fine at defaults but overrun the fixed
  // 65,536-float command buffer under show-time parameter changes.
  {
    file: new URL("../../static/vector/modules/lorenz-attractor.wasm", import.meta.url),
    abi: 2,
    params: [
      2, 1, 1.6, 0.8, 70 * Math.PI / 180,
      8 / 540, 1.5, 1, 1, 1, 999, 540 / 960,
    ],
    minimumSegments: 2300,
    expectedMoves: 1,
    expectedSplats: 0,
  },
  {
    file: new URL("../../static/vector/modules/electric-strips.wasm", import.meta.url),
    params: [
      8, 1, 3, 1, 0.35, 1, 1, 1, 1, 1.5,
      1, 1, 1, 0.3, 0.7, 1,
      1, 1,
    ],
    minimumSegments: 500,
    horizontalOnly: true,
  },
  {
    file: new URL("../../static/vector/modules/vector-scan-lines.wasm", import.meta.url),
    params: [
      0.7, 800 / 540, 8 / 540, 80 / 540, 160 / 540,
      2, 120 / 540, 8, 1,
      1, 1, 1, 0.2, 0.8, 1, 540 / 960,
    ],
    minimumSegments: 2500,
  },
];

function parseCommands(values, abi = 1) {
  let cursor = 0;
  let segments = 0;
  let splats = 0;
  let moves = 0;
  let nonVerticalSegments = 0;
  let nonHorizontalSegments = 0;
  let current = false;
  let currentX = 0;
  let currentY = 0;
  while (cursor < values.length) {
    const op = Math.trunc(values[cursor++]);
    if (op === 1) {
      cursor += 10;
      current = false;
    } else if (op === 2) {
      currentX = values[cursor];
      currentY = values[cursor + 1];
      cursor += 2;
      current = true;
    } else if (op === 3) {
      const nextX = values[cursor];
      const nextY = values[cursor + 1];
      cursor += 2;
      if (current) {
        segments++;
        if (Math.abs(nextX - currentX) > 1e-6) nonVerticalSegments++;
        if (Math.abs(nextY - currentY) > 1e-6) nonHorizontalSegments++;
      }
      currentX = nextX;
      currentY = nextY;
      current = true;
    } else if (op === 4) {
      if (current) segments++;
    } else if (abi >= 2 && op === 5) {
      cursor += 12;
      current = true;
      moves++;
    } else if (abi >= 2 && op === 6) {
      cursor += 12;
      if (current) segments++;
      current = true;
    } else if (abi >= 2 && op === 7) {
      cursor += 16;
      if (current) segments += 24;
      current = true;
    } else if (abi >= 2 && op === 8) {
      cursor += 12;
      splats++;
    } else {
      assert.fail(`unknown command ${op}`);
    }
    assert.ok(cursor <= values.length, "command stream is truncated");
  }
  return {
    segments, splats, moves, nonVerticalSegments, nonHorizontalSegments,
  };
}

for (const fixture of modules) {
  const bytes = await readFile(fixture.file);
  const { instance } = await WebAssembly.instantiate(bytes, {
    env: { abort() { throw new Error("AssemblyScript abort"); } },
  });
  const api = instance.exports;
  const expectedAbi = fixture.abi || 1;
  assert.equal(api.abi_version(), expectedAbi);
  assert.ok(api.params_capacity() >= fixture.params.length);
  const params = new Float32Array(
    api.memory.buffer, api.params_ptr(), api.params_capacity());
  params.fill(0);
  params.set(fixture.params);
  const used = api.render(1.25, 4.5);
  assert.ok(used > 0 && used <= api.commands_capacity());
  const commands = new Float32Array(
    api.memory.buffer, api.commands_ptr(), used);
  assert.ok([...commands].every(Number.isFinite));
  const parsed = parseCommands(commands, expectedAbi);
  assert.ok(
    parsed.segments >= fixture.minimumSegments,
    `${fixture.file.pathname}: expected at least ${fixture.minimumSegments} `
      + `segments, got ${parsed.segments}`);
  if (fixture.verticalOnly) {
    assert.equal(parsed.nonVerticalSegments, 0);
  }
  if (fixture.horizontalOnly) {
    assert.equal(parsed.nonHorizontalSegments, 0);
  }
  if (fixture.minimumSplats) {
    assert.ok(parsed.splats >= fixture.minimumSplats);
  }
  if (fixture.expectedMoves !== undefined) {
    assert.equal(parsed.moves, fixture.expectedMoves);
  }
  if (fixture.expectedSegments !== undefined) {
    assert.equal(parsed.segments, fixture.expectedSegments);
  }
  if (fixture.expectedSplats !== undefined) {
    assert.equal(parsed.splats, fixture.expectedSplats);
  }
}

console.log("vector WASM ABI and command streams: PASS");
