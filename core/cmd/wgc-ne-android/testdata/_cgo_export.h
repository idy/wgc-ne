// Standalone JNI C test fixture. Production uses cgo's generated header.
#ifndef WGC_NE_TEST_CGO_EXPORT_H
#define WGC_NE_TEST_CGO_EXPORT_H
#include "jni_bridge.h"
char *WGCNEAndroidValidate(char *config, int length);
char *WGCNEAndroidStart(int fd, char *config, int length, WGCNEProtector *protector);
char *WGCNEAndroidStatus(long long handle);
void WGCNEAndroidStop(long long handle);
#endif
