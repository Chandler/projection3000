#pragma once

#include <algorithm>
#include <cmath>

inline double ping_pong_position(
    double phase, double start, double end) {
    const double span = std::max(0.001, end - start);
    const double cycle = span * 2.0;
    double wrapped = std::fmod(phase, cycle);
    if (wrapped < 0.0) wrapped += cycle;
    return wrapped <= span
        ? start + wrapped
        : end - (wrapped - span);
}
