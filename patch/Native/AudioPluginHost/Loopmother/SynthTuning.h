#pragma once
#include <algorithm>
#include <cmath>

namespace loop2
{
// At full tracking, each octave on the keyboard doubles the cutoff.
inline float trackedCutoff(float baseHz, float noteHz, float tracking)
{
    return baseHz * std::pow(std::max(1.0f, noteHz) / 261.6256f,
                             std::clamp(tracking, 0.0f, 1.0f));
}
}
