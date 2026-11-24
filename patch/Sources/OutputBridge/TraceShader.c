#include "PatchTraceGPU.h"
const char* patch_trace_metal_math(void) {
#define PATCH_TRACE_MATH(...) #__VA_ARGS__
    return
#include "PatchTraceMath.inc"
    ;
#undef PATCH_TRACE_MATH
}
