#pragma once
#ifdef __cplusplus
extern "C" {
#endif
// The response contains {status,body}. The caller releases it with PatchLibraryFreeJSON.
char *PatchLibraryRequestJSON(const char *method, const char *path, const char *body);
void PatchLibraryFreeJSON(char *response);
#ifdef __cplusplus
}
#endif
