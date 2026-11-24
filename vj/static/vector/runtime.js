(function (global) {
  "use strict";

  const ABI_VERSION = 2;
  const SUPPORTED_ABIS = new Set([1, 2]);
  const OP_STYLE = 1;
  const OP_MOVE = 2;
  const OP_LINE = 3;
  const OP_CLOSE = 4;
  const OP_VERTEX_MOVE = 5;
  const OP_VERTEX_LINE = 6;
  const OP_VERTEX_CUBIC = 7;
  const OP_SPLAT = 8;
  const moduleCache = new Map();

  function finite(value, defaultValue = 0) {
    return Number.isFinite(value) ? value : defaultValue;
  }

  async function loadModule(url) {
    if (!moduleCache.has(url)) {
      moduleCache.set(url, (async () => {
        const response = await fetch(url, { cache: "no-cache" });
        if (!response.ok) {
          throw new Error(`vector module ${url}: HTTP ${response.status}`);
        }
        const bytes = await response.arrayBuffer();
        const imports = {
          env: {
            abort() {
              throw new Error(`vector module ${url} aborted`);
            },
          },
        };
        const result = await WebAssembly.instantiate(bytes, imports);
        const api = result.instance.exports;
        const required = [
          "memory", "abi_version", "params_ptr", "params_capacity",
          "commands_ptr", "commands_capacity", "render",
        ];
        for (const name of required) {
          if (!(name in api)) {
            throw new Error(`vector module ${url} lacks ${name}`);
          }
        }
        const abi = api.abi_version();
        if (!SUPPORTED_ABIS.has(abi)) {
          throw new Error(
            `vector module ${url} uses unsupported ABI ${abi}`);
        }
        return { api, abi };
      })().catch(error => {
        // A temporary fetch failure must not poison this module until reload.
        moduleCache.delete(url);
        throw error;
      }));
    }
    return moduleCache.get(url);
  }

  function parseCommands(values, abi = 1) {
    const groups = [];
    const richSegments = [];
    const splats = [];
    let group = null;
    let current = null;
    let pathStart = null;
    let richCurrent = null;

    function requireValues(index, count, op) {
      if (index + count > values.length) {
        throw new Error(`truncated vector opcode ${op}`);
      }
    }

    function readVertex(index) {
      requireValues(index, 12, "vertex");
      return {
        point: [finite(values[index]), finite(values[index + 1])],
        style: {
          core: [
            finite(values[index + 2]), finite(values[index + 3]),
            finite(values[index + 4]), finite(values[index + 5], 1),
          ],
          glow: [
            finite(values[index + 6]), finite(values[index + 7]),
            finite(values[index + 8]), finite(values[index + 9]),
          ],
          coreWidth: Math.max(0, finite(values[index + 10])),
          glowWidth: Math.max(0, finite(values[index + 11])),
        },
      };
    }

    function lerp(a, b, amount) {
      return a + (b - a) * amount;
    }

    function interpolateVertex(a, b, amount, point) {
      return {
        point,
        style: {
          core: a.style.core.map(
            (value, index) => lerp(value, b.style.core[index], amount)),
          glow: a.style.glow.map(
            (value, index) => lerp(value, b.style.glow[index], amount)),
          coreWidth: lerp(a.style.coreWidth, b.style.coreWidth, amount),
          glowWidth: lerp(a.style.glowWidth, b.style.glowWidth, amount),
        },
      };
    }

    for (let i = 0; i < values.length;) {
      const op = Math.trunc(values[i++]);
      if (op === OP_STYLE) {
        requireValues(i, 10, op);
        group = {
          style: {
            core: [
              finite(values[i]), finite(values[i + 1]),
              finite(values[i + 2]), finite(values[i + 3], 1),
            ],
            glow: [
              finite(values[i + 4]), finite(values[i + 5]),
              finite(values[i + 6]), finite(values[i + 7]),
            ],
            coreWidth: Math.max(0, finite(values[i + 8])),
            glowWidth: Math.max(0, finite(values[i + 9])),
          },
          segments: [],
        };
        i += 10;
        groups.push(group);
        current = pathStart = null;
      } else if (op === OP_MOVE) {
        requireValues(i, 2, op);
        current = [finite(values[i]), finite(values[i + 1])];
        pathStart = current;
        i += 2;
      } else if (op === OP_LINE) {
        requireValues(i, 2, op);
        const next = [finite(values[i]), finite(values[i + 1])];
        i += 2;
        if (group && current) group.segments.push([current, next]);
        current = next;
      } else if (op === OP_CLOSE) {
        if (group && current && pathStart
            && (current[0] !== pathStart[0] || current[1] !== pathStart[1])) {
          group.segments.push([current, pathStart]);
        }
        current = pathStart;
      } else if (abi >= 2 && op === OP_VERTEX_MOVE) {
        richCurrent = readVertex(i);
        i += 12;
      } else if (abi >= 2 && op === OP_VERTEX_LINE) {
        const next = readVertex(i);
        i += 12;
        if (richCurrent) {
          richSegments.push({
            a: richCurrent.point, b: next.point,
            styleA: richCurrent.style, styleB: next.style,
          });
        }
        richCurrent = next;
      } else if (abi >= 2 && op === OP_VERTEX_CUBIC) {
        requireValues(i, 16, op);
        const control1 = [finite(values[i]), finite(values[i + 1])];
        const control2 = [finite(values[i + 2]), finite(values[i + 3])];
        const next = readVertex(i + 4);
        i += 16;
        if (richCurrent) {
          const start = richCurrent;
          let previous = start;
          // Fixed, deterministic subdivision gives browser/native parity.
          // Twenty-four pieces are visually smooth at projector resolution
          // while keeping the command stream compact.
          const pieces = 24;
          for (let piece = 1; piece <= pieces; piece++) {
            const t = piece / pieces;
            const u = 1 - t;
            const point = [
              u * u * u * start.point[0]
                + 3 * u * u * t * control1[0]
                + 3 * u * t * t * control2[0]
                + t * t * t * next.point[0],
              u * u * u * start.point[1]
                + 3 * u * u * t * control1[1]
                + 3 * u * t * t * control2[1]
                + t * t * t * next.point[1],
            ];
            const sample = interpolateVertex(start, next, t, point);
            richSegments.push({
              a: previous.point, b: sample.point,
              styleA: previous.style, styleB: sample.style,
            });
            previous = sample;
          }
        }
        richCurrent = next;
      } else if (abi >= 2 && op === OP_SPLAT) {
        splats.push(readVertex(i));
        i += 12;
      } else {
        throw new Error(`unknown vector opcode ${op}`);
      }
    }
    return { groups, richSegments, splats };
  }

  class EffectHost {
    constructor() {
      this.moduleUrl = "";
      this.api = null;
      this.loading = null;
    }

    async setModule(url, expectedAbi = 1) {
      if (this.moduleUrl === url && this.api && this.abi === expectedAbi) return;
      this.moduleUrl = url;
      // Do not evaluate a new recipe with the previous module while loading.
      this.api = null;
      const loading = loadModule(url);
      this.loading = loading;
      const loaded = await loading;
      if (loaded.abi !== expectedAbi) {
        throw new Error(
          `graphics module ${url} uses ABI ${loaded.abi}, recipe expects ${expectedAbi}`);
      }
      if (this.loading === loading) {
        this.api = loaded.api;
        this.abi = loaded.abi;
      }
    }

    evaluate(recipe, seconds, beat) {
      const api = this.api;
      if (!api || recipe.module !== this.moduleUrl) return null;
      const params = Array.isArray(recipe.paramValues)
        ? recipe.paramValues : [];
      const paramCapacity = api.params_capacity();
      if (params.length > paramCapacity) {
        throw new Error(
          `vector recipe has ${params.length} params; module capacity is ${paramCapacity}`);
      }
      let memory = new Float32Array(api.memory.buffer);
      const paramsOffset = api.params_ptr() >>> 2;
      for (let i = 0; i < paramCapacity; i++) {
        memory[paramsOffset + i] = finite(params[i]);
      }
      const used = api.render(seconds, beat);
      const capacity = api.commands_capacity();
      if (used < 0 || used > capacity) {
        throw new Error(`vector module returned invalid command size ${used}`);
      }
      memory = new Float32Array(api.memory.buffer);
      const commandOffset = api.commands_ptr() >>> 2;
      return parseCommands(
        memory.subarray(commandOffset, commandOffset + used),
        finite(recipe.abi, 1));
    }
  }

  function rgba(color, opacity = 1) {
    const r = Math.round(Math.max(0, Math.min(1, color[0])) * 255);
    const g = Math.round(Math.max(0, Math.min(1, color[1])) * 255);
    const b = Math.round(Math.max(0, Math.min(1, color[2])) * 255);
    const a = Math.max(0, Math.min(1, color[3] * opacity));
    return `rgba(${r},${g},${b},${a})`;
  }

  function parseHexColor(text) {
    const match = /^#([0-9a-f]{6})$/i.exec(text || "");
    if (!match) return null;
    const value = Number.parseInt(match[1], 16);
    return [
      ((value >> 16) & 255) / 255,
      ((value >> 8) & 255) / 255,
      (value & 255) / 255,
    ];
  }

  function masterStyle(recipe, time) {
    const master = recipe?.master || {};
    let gain = Math.max(0, Math.min(1, finite(master.gain, 1)));
    const beat = finite(time?.globalBeat, time?.beat);
    if (master.mute || master.blackout) gain = 0;
    if (master.pulse) {
      gain *= 0.25 + 0.75 * Math.exp(-(beat - Math.floor(beat)) * 5);
    }
    if (master.strobe && ((beat * 2) % 1) >= 0.5) gain = 0;
    const cast = parseHexColor(master.cast);
    const castAmount = Math.max(
      0, Math.min(1, finite(master.castAmount)));
    return {
      gain,
      color(input) {
        const output = [...input];
        if (master.invert) {
          for (let i = 0; i < 3; i++) output[i] = 1 - output[i];
        }
        if (cast && castAmount > 0) {
          const luminance =
            output[0] * 0.299 + output[1] * 0.587 + output[2] * 0.114;
          for (let i = 0; i < 3; i++) {
            output[i] +=
              (luminance * cast[i] - output[i]) * castAmount;
          }
        }
        return output;
      },
    };
  }

  function drawScene(ctx, scene, options = {}) {
    if (!scene) return;
    const width = ctx.canvas.width;
    const height = ctx.canvas.height;
    const transform = options.transform
      || ((point) => [point[0] * width, point[1] * height]);
    const opacity = finite(options.opacity, 1);
    const color = options.color || (value => value);
    const scale = finite(options.strokeScale, height);
    const clip = options.clip;

    ctx.save();
    if (clip?.length) {
      ctx.beginPath();
      clip.forEach((point, index) => {
        if (index) ctx.lineTo(point[0], point[1]);
        else ctx.moveTo(point[0], point[1]);
      });
      ctx.closePath();
      ctx.clip();
    }
    ctx.lineCap = options.lineCap === "butt" ? "butt" : "round";
    ctx.lineJoin = "round";
    ctx.globalCompositeOperation = options.blend === "normal"
      ? "source-over" : "lighter";

    for (const group of scene.groups) {
      const path = new Path2D();
      let previous = null;
      for (const [a, b] of group.segments) {
        const pa = transform(a);
        const pb = transform(b);
        if (![...pa, ...pb].every(Number.isFinite)) continue;
        if (!previous
            || Math.abs(previous[0] - pa[0]) > 1e-4
            || Math.abs(previous[1] - pa[1]) > 1e-4) {
          path.moveTo(pa[0], pa[1]);
        }
        path.lineTo(pb[0], pb[1]);
        previous = pb;
      }
      const style = group.style;
      const coreWidth = Math.max(0.6, style.coreWidth * scale);
      const glowWidth = Math.max(0, style.glowWidth * scale);
      if (glowWidth > 0 && style.glow[3] > 0) {
        ctx.save();
        ctx.strokeStyle = rgba(color(style.glow), opacity);
        ctx.lineWidth = coreWidth + glowWidth * 0.55;
        if (options.fastGlow) {
          // Composer's efficient monitor trades the expensive Canvas2D
          // shadow filter for one translucent wide stroke. Dense electrical
          // effects can contain hundreds of independently styled segments;
          // blurring each one blocks browser input even on a fast machine.
          ctx.globalAlpha = 0.55;
          ctx.shadowBlur = 0;
        } else {
          ctx.shadowColor = rgba(color(style.glow), opacity);
          ctx.shadowBlur = glowWidth;
        }
        ctx.stroke(path);
        ctx.restore();
      }
      if (coreWidth > 0 && style.core[3] > 0) {
        ctx.strokeStyle = rgba(color(style.core), opacity);
        ctx.lineWidth = coreWidth;
        ctx.shadowBlur = 0;
        ctx.stroke(path);
      }
    }

    function endpointGradient(pa, pb, colorA, colorB) {
      const gradient = ctx.createLinearGradient(pa[0], pa[1], pb[0], pb[1]);
      gradient.addColorStop(0, rgba(color(colorA), opacity));
      gradient.addColorStop(1, rgba(color(colorB), opacity));
      return gradient;
    }

    // Graphics v2 paths carry color, opacity, and width at every vertex.
    // Curves arrive as short deterministic pieces, so Canvas2D can approximate
    // a continuously tapered ribbon while the native GPU interpolates the
    // same attributes exactly.
    for (const pass of ["glow", "core"]) {
      // Each rich curve is deterministically subdivided. Flat caps make
      // adjacent pieces meet without additive round-cap hotspots; explicit
      // splats remain round.
      ctx.lineCap = "butt";
      for (const segment of scene.richSegments || []) {
        const pa = transform(segment.a);
        const pb = transform(segment.b);
        if (![...pa, ...pb].every(Number.isFinite)) continue;
        const styleA = segment.styleA;
        const styleB = segment.styleB;
        const path = new Path2D();
        path.moveTo(pa[0], pa[1]);
        path.lineTo(pb[0], pb[1]);
        if (pass === "glow") {
          const glowWidth = Math.max(
            0, (styleA.glowWidth + styleB.glowWidth) * 0.5 * scale);
          const coreWidth = Math.max(
            0.6, (styleA.coreWidth + styleB.coreWidth) * 0.5 * scale);
          if (glowWidth <= 0
              || (styleA.glow[3] <= 0 && styleB.glow[3] <= 0)) continue;
          ctx.save();
          ctx.strokeStyle = endpointGradient(
            pa, pb, styleA.glow, styleB.glow);
          ctx.lineWidth = coreWidth + glowWidth * 0.55;
          if (options.fastGlow) {
            ctx.globalAlpha = 0.5;
            ctx.shadowBlur = 0;
          } else {
            const averageGlow = styleA.glow.map(
              (value, index) => (value + styleB.glow[index]) * 0.5);
            ctx.shadowColor = rgba(color(averageGlow), opacity);
            ctx.shadowBlur = glowWidth;
          }
          ctx.stroke(path);
          ctx.restore();
        } else {
          const coreWidth = Math.max(
            0.6, (styleA.coreWidth + styleB.coreWidth) * 0.5 * scale);
          if (styleA.core[3] <= 0 && styleB.core[3] <= 0) continue;
          ctx.strokeStyle = endpointGradient(
            pa, pb, styleA.core, styleB.core);
          ctx.lineWidth = coreWidth;
          ctx.shadowBlur = 0;
          ctx.stroke(path);
        }
      }
    }

    for (const splatItem of scene.splats || []) {
      const point = transform(splatItem.point);
      if (!point.every(Number.isFinite)) continue;
      const style = splatItem.style;
      const coreRadius = Math.max(0, style.coreWidth * scale * 0.5);
      const outerRadius = Math.max(
        coreRadius + 0.5, coreRadius + style.glowWidth * scale * 1.8);
      if (outerRadius > 0 && style.glow[3] > 0) {
        const gradient = ctx.createRadialGradient(
          point[0], point[1], coreRadius * 0.25,
          point[0], point[1], outerRadius);
        gradient.addColorStop(0, rgba(color(style.glow), opacity));
        const transparent = [...style.glow];
        transparent[3] = 0;
        gradient.addColorStop(1, rgba(color(transparent), opacity));
        ctx.fillStyle = gradient;
        ctx.beginPath();
        ctx.arc(point[0], point[1], outerRadius, 0, Math.PI * 2);
        ctx.fill();
      }
      if (coreRadius > 0 && style.core[3] > 0) {
        ctx.fillStyle = rgba(color(style.core), opacity);
        ctx.beginPath();
        ctx.arc(point[0], point[1], coreRadius, 0, Math.PI * 2);
        ctx.fill();
      }
    }
    ctx.restore();
  }

  function recipeTime(recipe, receivedAt, now) {
    const anchor = recipe?.clock || {};
    const elapsed = anchor.playing === false ? 0 : (now - receivedAt) / 1000;
    const seconds = finite(anchor.seconds) + elapsed;
    const beat = finite(anchor.beat) + elapsed * finite(anchor.bpm, 120) / 60;
    const globalBeat = finite(
      recipe?.master?.globalBeat, beat)
      + elapsed * finite(anchor.bpm, 120) / 60;
    return { seconds, beat, globalBeat };
  }

  class CanvasMonitor {
    constructor(canvases, options = {}) {
      this.canvases = (Array.isArray(canvases) ? canvases : [canvases])
        .filter(Boolean);
      this.host = new EffectHost();
      this.recipe = null;
      this.receivedAt = performance.now();
      this.running = true;
      this.paused = false;
      this.error = null;
      this.frameInterval = 0;
      this.lastDrawAt = -Infinity;
      this.fastGlow = false;
      this.setFrameRate(options.frameRate);
      this.setFastGlow(options.fastGlow);
      this.frame = requestAnimationFrame(now => this.tick(now));
    }

    async setRecipe(recipe, { preserveFrame = false } = {}) {
      this.recipe = recipe || null;
      this.receivedAt = performance.now();
      this.error = null;
      if (!recipe) {
        for (const canvas of preserveFrame ? [] : this.canvases) {
          canvas.getContext("2d").clearRect(0, 0, canvas.width, canvas.height);
        }
        return;
      }
      try {
        await this.host.setModule(recipe.module, finite(recipe.abi, 1));
      } catch (error) {
        if (this.recipe !== recipe) return;
        this.error = error;
        console.error(error);
      }
    }

    tick(now) {
      if (!this.running) return;
      this.frame = requestAnimationFrame(next => this.tick(next));
      if (!this.recipe || this.error || this.paused || document.hidden) return;
      if (now - this.lastDrawAt < this.frameInterval) return;
      this.lastDrawAt = now;
      try {
        const time = recipeTime(this.recipe, this.receivedAt, now);
        const scene = this.host.evaluate(
          this.recipe, time.seconds, time.beat);
        if (!scene) return;
        const master = masterStyle(this.recipe, time);
        for (const canvas of this.canvases) {
          // The same Program source backs the Compose and Mix monitors. Only
          // paint the one whose page is currently laid out.
          if (!canvas.isConnected || canvas.getClientRects().length === 0) continue;
          const ctx = canvas.getContext("2d");
          ctx.setTransform(1, 0, 0, 1, 0, 0);
          ctx.fillStyle = "#000";
          ctx.fillRect(0, 0, canvas.width, canvas.height);
          drawScene(ctx, scene, {
            opacity: finite(this.recipe.opacity, 1) * master.gain,
            blend: this.recipe.blend || "normal",
            color: master.color,
            fastGlow: this.fastGlow,
            lineCap: this.recipe.lineCap,
          });
        }
      } catch (error) {
        this.error = error;
        console.error(error);
      }
    }

    destroy() {
      this.running = false;
      cancelAnimationFrame(this.frame);
    }

    setPaused(paused) {
      this.paused = Boolean(paused);
    }

    setFrameRate(frameRate) {
      const fps = finite(Number(frameRate));
      this.frameInterval = fps > 0 ? 1000 / fps : 0;
      this.lastDrawAt = -Infinity;
    }

    setFastGlow(fastGlow) {
      this.fastGlow = Boolean(fastGlow);
    }
  }

  async function thumbnail(recipe) {
    const host = new EffectHost();
    await host.setModule(recipe.module, finite(recipe.abi, 1));
    const canvas = document.createElement("canvas");
    canvas.width = 192;
    canvas.height = 108;
    const ctx = canvas.getContext("2d");
    ctx.fillStyle = "#000";
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    for (const [seconds, beat] of [[1.4, 1.05], [2.2, 1.4], [3, 1.75]]) {
      drawScene(ctx, host.evaluate(recipe, seconds, beat), {
        blend: "add", lineCap: recipe.lineCap,
      });
    }
    return canvas.toDataURL("image/png").split(",")[1];
  }

  global.VibeVector = {
    ABI_VERSION,
    EffectHost,
    CanvasMonitor,
    drawScene,
    recipeTime,
    masterStyle,
    thumbnail,
  };
})(globalThis);
