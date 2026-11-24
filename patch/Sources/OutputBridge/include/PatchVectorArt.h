#pragma once
#include <simd/simd.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  simd_float4 pointWidth, core, glow;
} PatchStrokeVertex;
typedef struct {
  PatchStrokeVertex a, b;
} PatchStrokeSegment;
typedef struct PatchVectorProgram PatchVectorProgram;
PatchVectorProgram *patch_vector_create(const char *program);
void patch_vector_destroy(PatchVectorProgram *program);
// Segments are owned by this instance and remain valid until the next frame.
const PatchStrokeSegment *patch_vector_frame(PatchVectorProgram *program,
                                             const float *parameters,
                                             size_t parameterCount, double time,
                                             double beat, size_t *count);
#ifdef __cplusplus
}
#endif
