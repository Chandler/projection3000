#include "PatchVectorArt.h"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>
#include <vector>

namespace {
constexpr float TAU = 6.283185307179586f;
float fract(float x) { return x - std::floor(x); }
float mix(float a, float b, float t) { return a + (b - a) * t; }
float clamp01(float x) { return std::min(1.f, std::max(0.f, x)); }
float hash2(int a, int b, int seed = 0) {
  uint32_t bits = uint32_t(a) * 0x1f123bb5u + uint32_t(b) * 0x05491333u +
                  uint32_t(seed) * 0x6d2b79f5u;
  bits ^= bits >> 16;
  bits *= 0x7feb352du;
  bits ^= bits >> 15;
  bits *= 0x846ca68bu;
  bits ^= bits >> 16;
  return float(bits & 0x00ffffff) / 0x01000000;
}

struct Drawing {
  const float *values = nullptr;
  size_t valueCount = 0;
  std::vector<PatchStrokeSegment> segments;
  PatchStrokeVertex current{};
  float getParam(size_t i) const { return i < valueCount ? values[i] : 0; }
  void style(float r, float g, float b, float a, float gr, float gg, float gb,
             float ga, float width, float glow) {
    current.core = {r, g, b, a};
    current.glow = {gr, gg, gb, ga};
    current.pointWidth.z = width;
    current.pointWidth.w = glow;
  }
  void moveTo(float x, float y) {
    current.pointWidth.x = x;
    current.pointWidth.y = y;
  }
  void lineTo(float x, float y) {
    auto previous = current;
    moveTo(x, y);
    segments.push_back({previous, current});
  }
  void moveVertex(float x, float y, float r, float g, float b, float a,
                  float gr, float gg, float gb, float ga, float width,
                  float glow) {
    style(r, g, b, a, gr, gg, gb, ga, width, glow);
    moveTo(x, y);
  }
  template <class... Args> void lineVertex(Args... args) {
    auto previous = current;
    moveVertex(args...);
    segments.push_back({previous, current});
  }
  virtual void render(double time, double beat) = 0;
  virtual ~Drawing() = default;
};

struct VectorCube final : Drawing {
  static constexpr float VERTICES[] = {
      -1, -1, -1, 1, -1, -1, 1, 1, -1, -1, 1, -1,
      -1, -1, 1,  1, -1, 1,  1, 1, 1,  -1, 1, 1,
  };
  static constexpr int EDGES[] = {
      0, 1, 1, 2, 2, 3, 3, 0, 4, 5, 5, 6, 6, 7, 7, 4, 0, 4, 1, 5, 2, 6, 3, 7,
  };
  float projected[16]{};

  void render(double time, double) override {

    const auto master = getParam(0);
    const auto ax = (float)time * master * getParam(1) + getParam(12);
    const auto ay = (float)time * master * getParam(2) + getParam(13);
    const auto az = (float)time * master * getParam(3) + getParam(14);
    const auto perspective = getParam(4) >= 0.5;
    const auto size = getParam(5);
    const auto aspectScale = getParam(11);

    const auto cx = std::cos(ax), sx = std::sin(ax);
    const auto cy = std::cos(ay), sy = std::sin(ay);
    const auto cz = std::cos(az), sz = std::sin(az);

    for (auto i = 0; i < 8; i++) {
      const auto o = i * 3;
      const auto x = (VERTICES[o]);
      const auto y = (VERTICES[o + 1]);
      const auto z = (VERTICES[o + 2]);

      // Use Rz * Ry * Rx rotation order.
      const auto x1 = x;
      const auto y1 = y * cx - z * sx;
      const auto z1 = y * sx + z * cx;
      const auto x2 = x1 * cy + z1 * sy;
      const auto y2 = y1;
      const auto z2 = -x1 * sy + z1 * cy;
      const auto x3 = x2 * cz - y2 * sz;
      const auto y3 = x2 * sz + y2 * cz;
      const float fac =
          perspective ? (float)3.0 / (z2 + (float)4.5) : (float)1.0;
      const float scale = (perspective ? (float)0.28 : (float)0.21) * size;
      (projected[i * 2] = (float)0.5 + x3 * fac * scale * aspectScale);
      (projected[i * 2 + 1] = (float)0.5 + y3 * fac * scale);
    }

    style(1, 1, 1, 1, getParam(6), getParam(7), getParam(8), 0.82, getParam(9),
          getParam(10));
    for (auto edge = 0; edge < 12; edge++) {
      const auto a = (EDGES[edge * 2]);
      const auto b = (EDGES[edge * 2 + 1]);
      moveTo((projected[a * 2]), (projected[a * 2 + 1]));
      lineTo((projected[b * 2]), (projected[b * 2 + 1]));
    }
    return;
  }
};

struct LaserText final : Drawing {
  // Font outline geometry follows the 13 live controls as (op, x, y) triples.

  float p(int i) const { return getParam(i); }

  void render(double time, double beat) override {

    const auto count = fminf(10000, fmaxf(0, int(p(12))));
    float halfWidth = 0, halfHeight = 0;
    for (auto i = 0; i < count; i++) {
      halfWidth = fmaxf(halfWidth, std::abs(p(14 + i * 3)));
      halfHeight = fmaxf(halfHeight, std::abs(p(15 + i * 3)));
    }
    const auto aspect = fmaxf(0.001, p(11));
    const float size =
        fminf(p(6), fminf(float(0.45) / fmaxf(halfWidth * aspect, float(0.001)),
                          float(0.45) / fmaxf(halfHeight, float(0.001))));
    const float pulse =
        1.0 - p(9) * float(0.5 - 0.5 * cos(time * p(10) * M_PI * 2));
    const auto brightness = p(5) * pulse;
    style(0.8 + 0.2 * p(0), 0.8 + 0.2 * p(1), 0.8 + 0.2 * p(2), brightness,
          p(0), p(1), p(2), brightness, p(3), p(4));
    for (auto i = 0; i < count; i++) {
      const auto x = p(7) + p(14 + i * 3) * size * aspect;
      const auto y = p(8) + p(15 + i * 3) * size;
      if (p(13 + i * 3) == 2)
        moveTo(x, y);
      else
        lineTo(x, y);
    }
    return;
  }
};

struct LightningCells final : Drawing {
  static constexpr int COLUMNS = 10;
  static constexpr int ROWS = 128;
  static constexpr int HISTORY = 24;
  float coreCells[ROWS]{};
  float flowCells[ROWS]{};

  float pulseStart(int event, int column, float rate, float burst) {
    const auto spacing = (float)1.0 / rate;
    return (float)event * spacing +
           (hash2(column, event * 17 + 31) - (float)0.5) * spacing *
               (float)0.5 * burst;
  }

  void applyPulse(int column, int event, int salt, float now, float rate,
                  float speed, float jitter, float length, float decay,
                  float delay, float amplitudeScale, float burst) {
    const auto age = now - pulseStart(event, column, rate, burst) - delay;
    if (age < 0)
      return;
    const auto velocity =
        fmaxf((float)0.02, speed * mix((float)1.0 - jitter * (float)0.65,
                                       (float)1.0 + jitter * (float)1.2,
                                       hash2(column, event * 23 + 47, salt)));
    const auto position = age * velocity;
    if (position > (float)1.25)
      return;

    const auto amplitude =
        amplitudeScale *
        mix((float)1.0 - burst * (float)0.3, (float)1.0 + burst * (float)0.25,
            hash2(column, event * 29 + 59, salt)) *
        std::exp(-fmaxf((float)0.0, position - (float)0.15) * (float)0.22);
    const auto width =
        fmaxf((float)0.002, length * mix((float)1.0 - jitter * (float)0.35,
                                         (float)1.0 + jitter * (float)0.35,
                                         hash2(column, event * 31 + 71, salt)));
    const auto sigma = fmaxf(width * (float)0.22, (float)0.0005);

    for (auto row = 0; row < ROWS; row++) {
      const auto sample = ((float)row + (float)0.5) / (float)ROWS;
      const auto distance = sample - position;
      const auto head =
          std::exp((float)-0.5 * (distance / sigma) * (distance / sigma));
      const auto back =
          distance <= 0 ? clamp01((float)1.0 + distance / width) : (float)0.0;
      const auto passedFor = age - sample / velocity;
      const auto afterglow = passedFor >= 0
                                 ? std::exp(-passedFor * decay) * amplitude
                                 : (float)0.0;
      const auto core = head * amplitude;
      const auto flow =
          fmaxf((head * (float)0.55 + back * (float)0.75) * amplitude,
                afterglow * (float)0.55);
      if (core > (coreCells[row])) {
        (coreCells[row] = core);
      }
      if (flow > (flowCells[row])) {
        (flowCells[row] = flow);
      }
    }
  }

  void applySpark(float position, float gain, float width) {
    const auto sigma = fmaxf(width, (float)0.0005);
    for (auto row = 0; row < ROWS; row++) {
      const auto sample = ((float)row + (float)0.5) / (float)ROWS;
      const auto distance = sample - position;
      const auto flash =
          std::exp((float)-0.5 * (distance / sigma) * (distance / sigma)) *
          gain;
      if (flash > (flowCells[row])) {
        (flowCells[row] = flash);
      }
    }
  }

  float paletteChannel(float hue, float shift) {
    return (float)0.5 + (float)0.5 * std::cos(TAU * (hue - shift));
  }

  void render(double time, double) override {

    const auto rate = fmaxf((float)0.0, getParam(0));
    const auto burst = clamp01(getParam(1));
    const auto speed = fmaxf((float)0.05, getParam(2));
    const auto jitter = clamp01(getParam(3));
    const auto length = getParam(4);
    const auto tail = clamp01(getParam(5));
    const auto crackle = clamp01(getParam(6));
    const auto forks = clamp01(getParam(7));
    const auto topSpray = clamp01(getParam(8));
    const auto brightness = getParam(9);
    const auto coreR = getParam(10), coreG = getParam(11), coreB = getParam(12);
    const auto glowR = getParam(13), glowG = getParam(14), glowB = getParam(15);
    const auto rainbow = clamp01(getParam(16));
    const auto reverse = getParam(17) >= (float)0.5;
    const auto now = (float)time;
    if (rate <= 0 || brightness <= 0)
      return;

    const auto decay = (float)2.0 + ((float)1.0 - tail) * (float)22.0;
    const auto frame = (int)std::floor(now * (float)30.0);
    const auto cellHeight = (float)0.78 / (float)ROWS;
    const auto columnWidth = (float)1.0 / (float)COLUMNS;
    const auto columnInset = columnWidth * (float)0.045;

    for (auto column = 0; column < COLUMNS; column++) {
      for (auto row = 0; row < ROWS; row++) {
        (coreCells[row] = 0);
        (flowCells[row] = 0);
      }

      const auto offset = hash2(column, 5) * burst / rate;
      const auto localNow = now + offset;
      const auto currentEvent = (int)std::floor(localNow * rate);
      for (auto previous = 0; previous < HISTORY; previous++) {
        const auto event = currentEvent - previous;
        applyPulse(column, event, 0, localNow, rate, speed, jitter, length,
                   decay, 0, 1, burst);

        const auto childChance =
            clamp01(burst * (float)0.55 + forks * (float)0.35);
        if (hash2(column, event * 41 + 83) < childChance) {
          const auto childDelay =
              mix((float)0.06, (float)0.32, hash2(column, event * 43 + 89));
          const auto childGain =
              mix((float)0.25, (float)0.55, hash2(column, event * 47 + 97));
          applyPulse(column, event, 101, localNow, rate, speed, jitter,
                     length * (float)0.62, decay, childDelay, childGain, burst);
        }

        const auto start = pulseStart(event, column, rate, burst);
        if (topSpray > 0 &&
            hash2(column, event * 53 + 107) < topSpray * (float)0.7) {
          const auto ttl =
              mix((float)0.025, (float)0.12, hash2(column, event * 59 + 109));
          const auto sprayAge =
              localNow - start - hash2(column, event * 61 + 113) * (float)0.3;
          if (sprayAge >= 0 && sprayAge < ttl) {
            const auto randomPosition = hash2(column, event * 67 + 127);
            const auto position = randomPosition * randomPosition *
                                  randomPosition *
                                  ((float)0.05 + (float)0.28 * topSpray);
            applySpark(position,
                       ((float)1.0 - sprayAge / ttl) *
                           mix((float)0.35, (float)1.0,
                               hash2(column, event * 71 + 131)),
                       mix((float)0.002, (float)0.012 + (float)0.025 * crackle,
                           hash2(column, event * 73 + 137)));
          }
        }

        if (forks > 0 && hash2(column, event * 79 + 139) < forks) {
          const auto forkDelay =
              mix((float)0.12, (float)1.05, hash2(column, event * 83 + 149));
          const auto ttl =
              mix((float)0.025, (float)0.12, hash2(column, event * 89 + 151));
          const auto forkAge = localNow - start - forkDelay;
          if (forkAge >= 0 && forkAge < ttl) {
            const auto position =
                clamp01(forkDelay * speed +
                        (hash2(column, event * 97 + 157) - (float)0.5) *
                            ((float)0.015 + (float)0.16 * crackle));
            applySpark(position,
                       ((float)1.0 - forkAge / ttl) *
                           mix((float)0.35, (float)1.0,
                               hash2(column, event * 101 + 163)),
                       mix((float)0.002, (float)0.012 + (float)0.025 * crackle,
                           hash2(column, event * 103 + 167)));
          }
        }
      }

      const auto x0 = (float)column * columnWidth + columnInset;
      const auto x1 = (float)(column + 1) * columnWidth - columnInset;
      for (auto outputRow = 0; outputRow < ROWS; outputRow++) {
        const auto sourceRow = reverse ? ROWS - outputRow - 1 : outputRow;
        const auto sample = ((float)sourceRow + (float)0.5) / (float)ROWS;
        const auto noiseCell = sourceRow / 5;
        const auto noiseAmount =
            mix((float)1.0 - crackle * (float)0.9, (float)1.0,
                hash2(column * 257 + noiseCell, frame));
        const auto core = fminf(
            (float)1.4, (coreCells[sourceRow]) *
                            mix((float)1.0 - crackle * (float)0.15,
                                (float)1.0 + crackle * (float)0.15,
                                hash2(column * ROWS + sourceRow, frame + 173)));
        const auto flow =
            fminf((float)1.2, (flowCells[sourceRow]) * noiseAmount);
        const auto hue = sample + now * (float)0.09;
        const auto ionR = paletteChannel(hue, 0);
        const auto ionG = paletteChannel(hue, (float)0.3333333);
        const auto ionB = paletteChannel(hue, (float)0.6666667);
        const auto mixedGlowR = mix(glowR, ionR, rainbow);
        const auto mixedGlowG = mix(glowG, ionG, rainbow);
        const auto mixedGlowB = mix(glowB, ionB, rainbow);
        const auto red =
            clamp01((mixedGlowR * flow + coreR * core) * brightness);
        const auto green =
            clamp01((mixedGlowG * flow + coreG * core) * brightness);
        const auto blue =
            clamp01((mixedGlowB * flow + coreB * core) * brightness);
        if (fmaxf(red, fmaxf(green, blue)) < (float)0.004)
          continue;

        // A cell is a flat, hard-edged RGB rectangle. "Glow" above only affects
        // its color/brightness, exactly like the pixelated LED web monitor.
        style(red, green, blue, 1, 0, 0, 0, 0, cellHeight, 0);
        const auto y = ((float)outputRow + (float)0.5) / (float)ROWS;
        moveTo(x0, y);
        lineTo(x1, y);
      }
    }
    return;
  }
};

struct ScanLines final : Drawing {
  void render(double time, double beat) override {

    const auto angle = getParam(0);
    const auto rate = getParam(1);
    const auto spacing = fmaxf((float)0.008, getParam(2));
    const auto coreWidth = getParam(3);
    const auto glowWidth = getParam(4);
    const auto amount = getParam(5);
    const auto wave = getParam(6);
    const auto waveFrequency = getParam(7);
    const auto beatPulse = getParam(8);
    const auto coreR = getParam(9), coreG = getParam(10), coreB = getParam(11);
    const auto glowR = getParam(12), glowG = getParam(13), glowB = getParam(14);
    const auto aspect = getParam(15);

    const auto tx = std::cos(angle) * aspect;
    const auto ty = std::sin(angle);
    const auto nx = -std::sin(angle) * aspect;
    const auto ny = std::cos(angle);
    const float span = 2.8;
    const auto count = (int)fminf(240, std::ceil(span / spacing) + 2);
    const auto offset = fract((float)time * rate / spacing) * spacing;
    const auto beatEnvelope = std::exp(-fract((float)beat) * (float)5.0);
    const auto gain = amount * ((float)1.0 + beatPulse * beatEnvelope);

    for (auto line = 0; line < count; line++) {
      const auto normal = -span * (float)0.5 + (float)line * spacing + offset;
      const auto alternating =
          (float)0.72 + (float)0.28 * std::sin((float)line * (float)1.618 +
                                               (float)time * (float)0.7);
      style(coreR, coreG, coreB, gain * alternating, glowR, glowG, glowB,
            gain * alternating * (float)0.78, coreWidth, glowWidth);
      const auto points = wave > 0 ? 18 : 1;
      for (auto point = 0; point <= points; point++) {
        const auto along =
            -span * (float)0.5 + span * (float)point / (float)points;
        const auto bend = wave * std::sin(along * waveFrequency * TAU +
                                          (float)time * rate * (float)4.0 +
                                          (float)line * (float)0.37);
        const auto x = (float)0.5 + tx * along + nx * (normal + bend);
        const auto y = (float)0.5 + ty * along + ny * (normal + bend);
        if (point == 0)
          moveTo(x, y);
        else
          lineTo(x, y);
      }
    }
    return;
  }
};

struct Lorenz final : Drawing {
  void render(double time, double) override {

    const auto speed = getParam(0);
    const auto trailLength = clamp01(getParam(1));
    const auto zoom = getParam(2);
    const auto rotation = getParam(3);
    const auto tilt = getParam(4);
    const auto lineWidth = getParam(5);
    const auto brightness = getParam(6);
    const auto red = getParam(7), green = getParam(8), blue = getParam(9);
    const auto seed = (int)std::round(getParam(10));
    const auto aspect = getParam(11);
    const auto now = (float)time;

    // A long, deterministic canonical Lorenz orbit. Only a moving window of
    // this trajectory is emitted, so the front advances while the back fades.
    const auto pathPoints = 2400;
    const auto visiblePoints =
        (int)fmaxf(8, fminf((float)pathPoints,
                            std::round(trailLength * (float)pathPoints)));
    auto phase =
        fract(now * std::abs(speed) * (float)0.022 + hash2(seed, 41, 73));
    if (speed < 0)
      phase = (float)1.0 - phase;
    // Keep the moving window contiguous inside the deterministic trajectory.
    // That makes the output one path (one move followed by line commands),
    // rather than splitting it when a circular buffer wraps.
    const auto travelPoints = pathPoints - visiblePoints;
    const auto head =
        visiblePoints - 1 + (int)std::floor(phase * (float)(travelPoints + 1));

    const auto yaw = now * rotation + hash2(seed, 17, 31) * TAU;
    const auto cosYaw = std::cos(yaw), sinYaw = std::sin(yaw);
    const auto cosTilt = std::cos(tilt), sinTilt = std::sin(tilt);

    const float sigma = (float)10.0;
    const float rho = (float)28.0;
    const float beta = (float)2.6666667;
    const float dt = (float)0.006;
    const auto stride = 2;
    const auto warmup = 1000 + seed % 97;
    float x = (float)0.08 + hash2(seed, 1, 19) * (float)0.08;
    float y = (float)0.01 + hash2(seed, 2, 23) * (float)0.04;
    float z = (float)0.02 + hash2(seed, 3, 29) * (float)0.03;
    auto pointIndex = 0;

    for (auto step = 0; step < warmup + pathPoints * stride; step++) {
      // Midpoint integration keeps the numerical orbit smooth without storing
      // or shipping a baked curve.
      const auto dx = sigma * (y - x);
      const auto dy = x * (rho - z) - y;
      const auto dz = x * y - beta * z;
      const auto mx = x + dx * dt * (float)0.5;
      const auto my = y + dy * dt * (float)0.5;
      const auto mz = z + dz * dt * (float)0.5;
      x += sigma * (my - mx) * dt;
      y += (mx * (rho - mz) - my) * dt;
      z += (mx * my - beta * mz) * dt;

      if (step < warmup || (step - warmup) % stride != 0)
        continue;
      const auto distanceBehind = head - pointIndex;
      const auto visible =
          distanceBehind >= 0 && distanceBehind < visiblePoints;
      if (visible) {
        const auto horizontal = x * cosYaw - y * sinYaw;
        const auto yawDepth = x * sinYaw + y * cosYaw;
        const auto centeredZ = z - rho * (float)0.9;
        const auto vertical = centeredZ * cosTilt - yawDepth * sinTilt;
        const auto px = (float)0.5 + horizontal * zoom * aspect / (float)36.0;
        const auto py = (float)0.51 - vertical * zoom / (float)43.0;

        if (distanceBehind == visiblePoints - 1) {
          moveVertex(px, py, red, green, blue, brightness, red, green, blue, 0,
                     lineWidth, 0);
        } else {
          lineVertex(px, py, red, green, blue, brightness, red, green, blue, 0,
                     lineWidth, 0);
        }
      }
      pointIndex++;
    }
    return;
  }
};

struct SlimeMold final : Drawing {
  float x[600]{};
  float y[600]{};
  float dist[600]{};
  float cost[600]{};
  float mass[600]{};
  float tx[600]{};
  float ty[600]{};
  int parent[600]{};
  int order[600]{};
  int used[600]{};
  float cache[6]{};
  bool ready = false;
  void build(int n) {
    auto changed = !ready;
    for (auto k = 0; k < 6; k++) {
      const auto v = getParam(k == 5 ? 12 : k);
      if (cache[k] != v)
        changed = true;
      cache[k] = v;
    }
    if (!changed)
      return;
    ready = true;
    const int seed = (int)getParam(0);
    const float aspect = getParam(12);
    x[0] = getParam(3);
    y[0] = getParam(4);
    for (auto i = 1; i < n; i++) {
      x[i] = hash2(i, seed, 17);
      y[i] = hash2(i, seed, 41);
      if (i <= 40) {
        const auto side = i % 4;
        const auto t = (float)(i / 4) / 10;
        if (side == 0) {
          x[i] = 0;
          y[i] = t;
        } else if (side == 1) {
          x[i] = 1;
          y[i] = t;
        } else if (side == 2) {
          x[i] = t;
          y[i] = 0;
        } else {
          x[i] = t;
          y[i] = 1;
        }
      }
    }
    for (auto i = 0; i < n; i++) {
      cost[i] = 1e9;
      used[i] = 0;
      mass[i] = 1;
      dist[i] = 0;
      parent[i] = 0;
    }
    cost[0] = 0;
    // Cached rooted spatial tree, with a path-cost bias for radial growth.
    for (auto k = 0; k < n; k++) {
      int a = 0;
      float score = 1e10;
      for (auto i = 0; i < n; i++)
        if (used[i] == 0 && cost[i] < score) {
          a = i;
          score = cost[i];
        }
      used[a] = 1;
      order[k] = a;
      if (a != 0) {
        const auto p = parent[a];
        const auto dx = (x[a] - x[p]) / aspect, dy = y[a] - y[p];
        dist[a] = dist[p] + std::sqrt(dx * dx + dy * dy);
      }
      for (auto b = 1; b < n; b++)
        if (used[b] == 0) {
          const auto dx = (x[a] - x[b]) / aspect, dy = y[a] - y[b];
          const auto v =
              std::sqrt(dx * dx + dy * dy) + dist[a] * getParam(2) * (float).35;
          if (v < cost[b]) {
            cost[b] = v;
            parent[b] = a;
          }
        }
    }
    for (auto k = n - 1; k > 0; k--) {
      const auto a = order[k];
      mass[parent[a]] += mass[a];
    }
    // Smooth the main vein through each fork; side branches leave along that
    // tangent instead of forming a rigid star of straight segments.
    for (auto a = 0; a < n; a++) {
      int child = -1;
      float biggest = 0;
      for (auto b = 1; b < n; b++)
        if (parent[b] == a && mass[b] > biggest) {
          child = b;
          biggest = mass[b];
        }
      const auto p = parent[a];
      auto dx = (x[a] - x[p]) / aspect, dy = y[a] - y[p];
      if (child >= 0) {
        dx = (x[child] - x[p]) / aspect;
        dy = y[child] - y[p];
      }
      const auto norm = fmaxf((float).00001, std::sqrt(dx * dx + dy * dy));
      tx[a] = dx / norm;
      ty[a] = dy / norm;
    }
  }
  void render(double time, double) override {
    const int n = std::max(1, std::min(600, (int)getParam(1)));
    build(n);
    const auto width = getParam(5), pulse = getParam(6), speed = getParam(7),
               length = getParam(8), r = getParam(9), g = getParam(10),
               b = getParam(11);
    for (auto i = 1; i < n; i++) {
      const auto p = parent[i];
      const auto aspect = getParam(12);
      const auto dx = (x[i] - x[p]) / aspect, dy = y[i] - y[p];
      const auto span = std::sqrt(dx * dx + dy * dy);
      const auto leaf = mass[i] == 1;
      const auto bend =
          (hash2(i, (int)getParam(0), 93) - (float).5) * (float)1.4;
      const auto startX = p == 0 ? dx / fmaxf(span, (float).00001) : tx[p];
      const auto startY = p == 0 ? dy / fmaxf(span, (float).00001) : ty[p];
      // Cubic paths preserve forks but turn terminal sticks into curling tips.
      const auto endX =
          leaf ? tx[i] * std::cos(bend) - ty[i] * std::sin(bend) : tx[i];
      const auto endY =
          leaf ? tx[i] * std::sin(bend) + ty[i] * std::cos(bend) : ty[i];
      const auto ax = x[p] + startX * span * aspect * (float).38,
                 ay = y[p] + startY * span * (float).38;
      const auto bx = x[i] - endX * span * aspect * (float).38,
                 by = y[i] - endY * span * (float).38;
      const auto w = width * ((float).65 + std::sqrt(mass[i] / (float)n) * 4);
      for (auto j = 0; j <= 7; j++) {
        const auto t = (float)j / 7, u = (float)1 - t,
                   d = dist[p] + (dist[i] - dist[p]) * t,
                   phase = d - (float)time * speed;
        const auto wrapped =
            phase - std::floor(phase / (float).65) * (float).65;
        const auto light =
            (float)1 - pulse +
            pulse * ((float).15 + (float).85 * std::exp(-wrapped * wrapped /
                                                        (length * length)));
        const auto ripple = std::sin(t * (float)3.14159265) *
                            std::sin(t * (float)3.14159265) * bend * (float).18;
        const auto px =
            fmaxf(0, fminf(1, u * u * u * x[p] + 3 * u * u * t * ax +
                                  3 * u * t * t * bx + t * t * t * x[i] -
                                  dy * aspect * ripple));
        const auto py =
            fmaxf(0, fminf(1, u * u * u * y[p] + 3 * u * u * t * ay +
                                  3 * u * t * t * by + t * t * t * y[i] +
                                  dx * ripple));
        const auto taper = leaf ? std::sqrt(u) : (float)1;
        if (j == 0)
          moveVertex(px, py, r * light, g * light, b * light, 1, 0, 0, 0, 0, w,
                     0);
        else
          lineVertex(px, py, r * light, g * light, b * light, taper, 0, 0, 0, 0,
                     w * ((float).1 + (float).9 * taper), 0);
      }
    }
    return;
  }
};
} // namespace
struct PatchVectorProgram {
  std::unique_ptr<Drawing> drawing;
};
extern "C" PatchVectorProgram *patch_vector_create(const char *program) {
  if (!program)
    return nullptr;
  std::unique_ptr<Drawing> drawing;
  if (std::strcmp(program, "vector-cube") == 0)
    drawing = std::make_unique<VectorCube>();
  else if (std::strcmp(program, "laser-text") == 0)
    drawing = std::make_unique<LaserText>();
  else if (std::strcmp(program, "electric-strips") == 0)
    drawing = std::make_unique<LightningCells>();
  else if (std::strcmp(program, "vector-scan-lines") == 0)
    drawing = std::make_unique<ScanLines>();
  else if (std::strcmp(program, "lorenz-attractor") == 0)
    drawing = std::make_unique<Lorenz>();
  else if (std::strcmp(program, "slime-mold") == 0)
    drawing = std::make_unique<SlimeMold>();
  else
    return nullptr;
  return new PatchVectorProgram{std::move(drawing)};
}
extern "C" void patch_vector_destroy(PatchVectorProgram *program) {
  delete program;
}
extern "C" const PatchStrokeSegment *
patch_vector_frame(PatchVectorProgram *program, const float *parameters,
                   size_t parameterCount, double time, double beat,
                   size_t *count) {
  *count = 0;
  if (!program || !parameters || !std::isfinite(time) || !std::isfinite(beat))
    return nullptr;
  auto &drawing = *program->drawing;
  drawing.values = parameters;
  drawing.valueCount = parameterCount;
  drawing.segments.clear();
  drawing.render(time, beat);
  drawing.values = nullptr;
  drawing.valueCount = 0;
  *count = drawing.segments.size();
  return drawing.segments.data();
}
