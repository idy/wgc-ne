#ifndef WGC_NE_JNI_BRIDGE_H
#define WGC_NE_JNI_BRIDGE_H

#include <jni.h>

#if defined(__ANDROID__) && __ANDROID_API__ < 23
#error "WGC NE requires Android API 23 or newer"
#endif

// Opaque C-owned state; contains a JavaVM and global jobject reference only.
typedef struct WGCNEProtector WGCNEProtector;

void wgc_ne_protector_retain(WGCNEProtector *protector);
void wgc_ne_protector_release(WGCNEProtector *protector);
int wgc_ne_protector_protect(WGCNEProtector *protector, int fd);

#endif
