//go:build android && cgo

#include "jni_bridge.h"
#include "_cgo_export.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>

#define WGC_NE_MAX_CONFIG_BYTES (128 * 1024)

struct WGCNEProtector {
    JavaVM *vm;
    jobject object;
    jmethodID protect;
    atomic_uint references;
    struct WGCNEProtector *retired_next;
};

// If the VM temporarily refuses to attach a retiring Go thread, keep the global
// reference reachable until a Java/JNI call supplies a valid JNIEnv. Never lose
// the only token needed to delete it. Normal failure/Stop calls already arrive
// on attached Java threads and drain this list before returning to Java.
static pthread_mutex_t retired_mutex = PTHREAD_MUTEX_INITIALIZER;
static WGCNEProtector *retired;

static void drain_retired(JNIEnv *env) {
    pthread_mutex_lock(&retired_mutex);
    WGCNEProtector *next = retired;
    retired = NULL;
    pthread_mutex_unlock(&retired_mutex);
    while (next != NULL) {
        WGCNEProtector *value = next;
        next = value->retired_next;
        (*env)->DeleteGlobalRef(env, value->object);
        free(value);
    }
}

static int clear_exception(JNIEnv *env) {
    if ((*env)->ExceptionCheck(env)) {
        // Exceptions can contain host/configuration data. Do not describe/log.
        (*env)->ExceptionClear(env);
        return 1;
    }
    return 0;
}

// JNIEnv is thread-local. A Go callback may arrive on any OS thread; only detach
// threads attached by this function, never Java's calling thread.
static JNIEnv *get_env(JavaVM *vm, int *attached) {
    JNIEnv *env = NULL;
    *attached = 0;
    jint result = (*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6);
    if (result == JNI_OK) {
        return env;
    }
    if (result != JNI_EDETACHED ||
        (*vm)->AttachCurrentThread(vm, &env, NULL) != JNI_OK) {
        return NULL;
    }
    *attached = 1;
    return env;
}

static WGCNEProtector *new_protector(JNIEnv *env, jobject object) {
    if (object == NULL) {
        return NULL;
    }
    WGCNEProtector *protector = calloc(1, sizeof(*protector));
    if (protector == NULL) {
        return NULL;
    }
    if ((*env)->GetJavaVM(env, &protector->vm) != JNI_OK) {
        clear_exception(env);
        free(protector);
        return NULL;
    }
    jclass clazz = (*env)->GetObjectClass(env, object);
    if (clear_exception(env) || clazz == NULL) {
        free(protector);
        return NULL;
    }
    protector->protect = (*env)->GetMethodID(env, clazz, "protect", "(I)Z");
    (*env)->DeleteLocalRef(env, clazz);
    if (clear_exception(env) || protector->protect == NULL) {
        free(protector);
        return NULL;
    }
    protector->object = (*env)->NewGlobalRef(env, object);
    if (clear_exception(env) || protector->object == NULL) {
        if (protector->object != NULL) {
            (*env)->DeleteGlobalRef(env, protector->object);
        }
        free(protector);
        return NULL;
    }
    atomic_init(&protector->references, 1);
    return protector;
}

void wgc_ne_protector_retain(WGCNEProtector *protector) {
    atomic_fetch_add_explicit(&protector->references, 1, memory_order_relaxed);
}

void wgc_ne_protector_release(WGCNEProtector *protector) {
    if (atomic_fetch_sub_explicit(&protector->references, 1, memory_order_acq_rel) != 1) {
        return;
    }
    int attached;
    JNIEnv *env = get_env(protector->vm, &attached);
    if (env == NULL) {
        pthread_mutex_lock(&retired_mutex);
        protector->retired_next = retired;
        retired = protector;
        pthread_mutex_unlock(&retired_mutex);
        return;
    }
    drain_retired(env);
    (*env)->DeleteGlobalRef(env, protector->object);
    if (attached) {
        (*protector->vm)->DetachCurrentThread(protector->vm);
    }
    free(protector);
}

int wgc_ne_protector_protect(WGCNEProtector *protector, int fd) {
    if (fd < 0) {
        return 0;
    }
    int attached;
    JNIEnv *env = get_env(protector->vm, &attached);
    if (env == NULL) {
        return 0;
    }
    drain_retired(env);
    jboolean result = (*env)->CallBooleanMethod(env, protector->object, protector->protect, (jint)fd);
    if (clear_exception(env)) {
        result = JNI_FALSE;
    }
    if (attached) {
        (*protector->vm)->DetachCurrentThread(protector->vm);
    }
    return result == JNI_TRUE;
}

// Copy before entering Go: never pin a Java array across a blocking startup.
// Invalid arguments and JNI copy failures become bounded/redacted native errors.
static char *copy_configuration(JNIEnv *env, jbyteArray configuration, int *length) {
    *length = 0;
    if (configuration == NULL) {
        return NULL;
    }
    jsize count = (*env)->GetArrayLength(env, configuration);
    if (clear_exception(env) || count <= 0 || count > WGC_NE_MAX_CONFIG_BYTES) {
        return NULL;
    }
    char *data = malloc((size_t)count);
    if (data == NULL) {
        return NULL;
    }
    (*env)->GetByteArrayRegion(env, configuration, 0, count, (jbyte *)data);
    if (clear_exception(env)) {
        free(data);
        return NULL;
    }
    *length = (int)count;
    return data;
}

static jstring response_string(JNIEnv *env, char *response) {
    drain_retired(env);
    // All envelope content is ASCII (stable errors, numeric settings, Base64
    // public keys), so NewStringUTF's modified UTF-8 representation is exact.
    jstring result = (*env)->NewStringUTF(env, response);
    free(response);
    return result;
}

JNIEXPORT jstring JNICALL Java_dev_idy_wgcne_NativeCore_validate(
    JNIEnv *env, jclass clazz, jbyteArray configuration) {
    (void)clazz;
    int length;
    char *data = copy_configuration(env, configuration, &length);
    char *response = WGCNEAndroidValidate(data, length);
    free(data);
    return response_string(env, response);
}

JNIEXPORT jstring JNICALL Java_dev_idy_wgcne_NativeCore_start(
    JNIEnv *env, jclass clazz, jint owned_fd, jbyteArray configuration, jobject object) {
    (void)clazz;
    int length;
    char *data = copy_configuration(env, configuration, &length);
    WGCNEProtector *protector = new_protector(env, object);
    // Never return early: Go ALWAYS consumes owned_fd, even for a null array,
    // invalid length, failed protector/global-ref creation, or invalid fd.
    char *response = WGCNEAndroidStart(owned_fd, data, length, protector);
    free(data);
    return response_string(env, response);
}

JNIEXPORT jstring JNICALL Java_dev_idy_wgcne_NativeCore_status(
    JNIEnv *env, jclass clazz, jlong handle) {
    (void)clazz;
    return response_string(env, WGCNEAndroidStatus((long long)handle));
}

JNIEXPORT void JNICALL Java_dev_idy_wgcne_NativeCore_stop(
    JNIEnv *env, jclass clazz, jlong handle) {
    (void)clazz;
    WGCNEAndroidStop((long long)handle);
    drain_retired(env);
}
