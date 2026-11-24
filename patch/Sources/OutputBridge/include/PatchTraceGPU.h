#pragma once
#include "PatchTrace.h"
// The Swift/Metal upload layouts instantiate the same definitions at GPU precision.
#define PatchTraceReal float
#define PatchTraceColor PatchGPUTraceColor
#define PatchTraceConfig PatchGPUTraceConfig
#define PatchLineTrace PatchGPULineTrace
#define patch_trace_mod patch_gpu_trace_mod
#define patch_trace_clamp patch_gpu_trace_clamp
#define patch_trace_glow patch_gpu_trace_glow
#define patch_trace_sample patch_gpu_trace_sample
#define patch_line_sample patch_gpu_line_sample
#define PATCH_TRACE_ADDRESS
#define PATCH_TRACE_MATH(...) __VA_ARGS__
#include "PatchTraceMath.inc"
#undef PATCH_TRACE_MATH
#undef PATCH_TRACE_ADDRESS
#undef patch_line_sample
#undef patch_trace_sample
#undef patch_trace_glow
#undef patch_trace_clamp
#undef patch_trace_mod
#undef PatchLineTrace
#undef PatchTraceConfig
#undef PatchTraceColor
#undef PatchTraceReal
#ifdef __cplusplus
extern "C" {
#endif
const char* patch_trace_metal_math(void);
#ifdef __cplusplus
}
#endif
