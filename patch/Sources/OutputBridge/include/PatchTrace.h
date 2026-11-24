#pragma once
#include <math.h>
#include <stdint.h>
typedef double PatchTraceReal;
typedef uint32_t PatchTraceSeed;
#define PATCH_TRACE_ADDRESS
#define PATCH_TRACE_MATH(...) __VA_ARGS__
#include "PatchTraceMath.inc"
#undef PATCH_TRACE_MATH
#undef PATCH_TRACE_ADDRESS
