#ifndef WGC_NE_CORE_H
#define WGC_NE_CORE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
int32_t WGCNEABIVersion(void);
char *WGCNEValidate(const char *config, int32_t length);
/* Always owns owned_fd, even if validation or startup fails. */
char *WGCNEStart(int32_t owned_fd, const char *config, int32_t length);
char *WGCNEStatus(uint64_t handle);
void WGCNEStop(uint64_t handle);
void WGCNEFree(char *value);
#ifdef __cplusplus
}
#endif
#endif
