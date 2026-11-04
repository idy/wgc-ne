// Standalone tests for the production C bridge using a fake JNI VM. Compile
// with the NDK's VM-neutral jni.h on the host; no Android device/JVM is needed.
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "../jni_bridge.c"

static JNIEnv test_env;
static JavaVM test_vm;
static _Thread_local int attached;
static _Thread_local int exception;
static atomic_int globals, deleted, attaches, detaches, starts;
static int reject_method, reject_global, reject_array, reject_attach;
static int callback_exception, callback_result = JNI_TRUE;
static int last_length;

typedef struct { jsize length; jbyte *bytes; } TestArray;

static jint get_vm(JNIEnv *env, JavaVM **vm) {
    (void)env;
    *vm = &test_vm;
    return JNI_OK;
}
static jclass object_class(JNIEnv *env, jobject object) { (void)env; return object; }
static jmethodID method(JNIEnv *env, jclass clazz, const char *name, const char *signature) {
    (void)env; (void)clazz;
    assert(strcmp(name, "protect") == 0 && strcmp(signature, "(I)Z") == 0);
    if (reject_method) { exception = 1; return NULL; }
    return (jmethodID)(uintptr_t)2;
}
static jobject global(JNIEnv *env, jobject object) {
    (void)env;
    if (reject_global) { exception = 1; return NULL; }
    atomic_fetch_add(&globals, 1);
    return object;
}
static void delete_global(JNIEnv *env, jobject object) {
    (void)env;
    assert(attached && object != NULL);
    atomic_fetch_add(&deleted, 1);
}
static void delete_local(JNIEnv *env, jobject object) { (void)env; (void)object; }
static jboolean has_exception(JNIEnv *env) { (void)env; return exception; }
static void clear(JNIEnv *env) { (void)env; exception = 0; }
static jboolean call(JNIEnv *env, jobject object, jmethodID method_id, ...) {
    (void)env; (void)object; (void)method_id;
    assert(attached);
    if (callback_exception) { exception = 1; }
    return callback_result;
}
static jsize array_length(JNIEnv *env, jarray array) { (void)env; return ((TestArray *)array)->length; }
static void array_copy(JNIEnv *env, jbyteArray array, jsize start, jsize length, jbyte *bytes) {
    (void)env;
    if (reject_array) { exception = 1; return; }
    memcpy(bytes, ((TestArray *)array)->bytes + start, (size_t)length);
}
static jstring string(JNIEnv *env, const char *value) { (void)env; return (jstring)strdup(value); }
static jint env_for_thread(JavaVM *vm, void **env, jint version) {
    (void)vm;
    assert(version == JNI_VERSION_1_6);
    if (!attached) { return JNI_EDETACHED; }
    *env = &test_env;
    return JNI_OK;
}
static jint attach(JavaVM *vm, JNIEnv **env, void *args) {
    (void)vm; (void)args;
    if (reject_attach) { return JNI_ERR; }
    assert(!attached);
    attached = 1;
    *env = &test_env;
    atomic_fetch_add(&attaches, 1);
    return JNI_OK;
}
static jint detach(JavaVM *vm) {
    (void)vm;
    assert(attached && !exception);
    attached = 0;
    atomic_fetch_add(&detaches, 1);
    return JNI_OK;
}

static const struct JNINativeInterface jni = {
    .GetJavaVM = get_vm, .GetObjectClass = object_class, .GetMethodID = method,
    .NewGlobalRef = global, .DeleteGlobalRef = delete_global, .DeleteLocalRef = delete_local,
    .ExceptionCheck = has_exception, .ExceptionClear = clear, .CallBooleanMethod = call,
    .GetArrayLength = array_length, .GetByteArrayRegion = array_copy, .NewStringUTF = string,
};
static const struct JNIInvokeInterface vm = {
    .GetEnv = env_for_thread, .AttachCurrentThread = attach, .DetachCurrentThread = detach,
};

// Stub only the Go boundary. These tests prove JNI always transfers ownership;
// the Go bridge tests separately prove closure/release after validation/start.
char *WGCNEAndroidValidate(char *config, int length) {
    assert((config == NULL) == (length == 0));
    last_length = length;
    return strdup("{\"ok\":false}");
}
char *WGCNEAndroidStart(int fd, char *config, int length, WGCNEProtector *protector) {
    atomic_fetch_add(&starts, 1);
    assert((config == NULL) == (length == 0));
    last_length = length;
    if (fd >= 0) { assert(close(fd) == 0); }
    if (protector != NULL) { wgc_ne_protector_release(protector); }
    return strdup("{\"ok\":false}");
}
char *WGCNEAndroidStatus(long long handle) { (void)handle; return strdup("{\"ok\":false}"); }
void WGCNEAndroidStop(long long handle) { (void)handle; }

static void start_case(TestArray *array, jobject protector) {
    int pipe_fds[2];
    assert(pipe(pipe_fds) == 0);
    int before = atomic_load(&starts);
    jstring response = Java_dev_idy_wgcne_NativeCore_start(&test_env, NULL, pipe_fds[0], (jbyteArray)array, protector);
    assert(strcmp((char *)response, "{\"ok\":false}") == 0);
    free(response);
    assert(atomic_load(&starts) == before + 1);
    assert(fcntl(pipe_fds[0], F_GETFD) == -1 && errno == EBADF);
    assert(close(pipe_fds[1]) == 0);
    assert(!exception && atomic_load(&globals) == atomic_load(&deleted));
}

static void *thread_callback(void *value) {
    WGCNEProtector *protector = value;
    assert(!attached);
    assert(wgc_ne_protector_protect(protector, 42) == (!reject_attach && !callback_exception && callback_result));
    assert(!attached && !exception);
    wgc_ne_protector_release(protector);
    return NULL;
}

int main(void) {
    test_env = &jni;
    test_vm = &vm;
    attached = 1; // Java's thread must never be detached by a native callback.
    TestArray valid = {2, (jbyte *)"{}"};
    TestArray empty = {0, NULL};
    TestArray huge = {WGC_NE_MAX_CONFIG_BYTES + 1, NULL};
    jobject object = (jobject)(uintptr_t)1;
    start_case(NULL, object);
    start_case(&empty, object);
    start_case(&huge, object);
    assert(last_length == 0);
    start_case(&valid, NULL);
    reject_array = 1;
    start_case(&valid, object);
    assert(last_length == 0);
    reject_array = 0;
    reject_method = 1;
    start_case(&valid, object);
    reject_method = 0;
    reject_global = 1;
    start_case(&valid, object);
    reject_global = 0;
    start_case(&valid, object);
    assert(last_length == 2);

    WGCNEProtector *protector = new_protector(&test_env, object);
    assert(protector != NULL);
    assert(wgc_ne_protector_protect(protector, 42));
    assert(attached && atomic_load(&detaches) == 0);
    callback_result = JNI_FALSE;
    assert(!wgc_ne_protector_protect(protector, 42));
    callback_result = JNI_TRUE;
    callback_exception = 1;
    assert(!wgc_ne_protector_protect(protector, 42));
    assert(!exception && attached);
    callback_exception = 0;

    for (int failure = 0; failure < 3; failure++) {
        reject_attach = failure == 1;
        callback_exception = failure == 2;
        wgc_ne_protector_retain(protector);
        pthread_t thread;
        assert(pthread_create(&thread, NULL, thread_callback, protector) == 0);
        assert(pthread_join(thread, NULL) == 0);
    }
    reject_attach = 0;
    callback_exception = 0;
    assert(atomic_load(&attaches) == 2 && atomic_load(&detaches) == 2);
    assert(atomic_load(&globals) == atomic_load(&deleted) + 1);
    // An in-flight callback retains the global ref after the owner releases it.
    wgc_ne_protector_retain(protector);
    wgc_ne_protector_release(protector);
    assert(atomic_load(&globals) == atomic_load(&deleted) + 1);
    pthread_t final_thread;
    assert(pthread_create(&final_thread, NULL, thread_callback, protector) == 0);
    assert(pthread_join(final_thread, NULL) == 0);
    assert(atomic_load(&globals) == atomic_load(&deleted));
    assert(atomic_load(&attaches) == atomic_load(&detaches));

    // Attachment can fail during asynchronous retirement as well as protection.
    // Keep the deletion token, then drain it on the next attached JNI call.
    protector = new_protector(&test_env, object);
    reject_attach = 1;
    assert(pthread_create(&final_thread, NULL, thread_callback, protector) == 0);
    assert(pthread_join(final_thread, NULL) == 0);
    assert(atomic_load(&globals) == atomic_load(&deleted) + 1);
    reject_attach = 0;
    jstring response = Java_dev_idy_wgcne_NativeCore_status(&test_env, NULL, 0);
    free(response);
    assert(atomic_load(&globals) == atomic_load(&deleted));
    assert(attached && !exception);
    puts("JNI protection, exceptions, thread attachment, ownership, and reference tests passed");
    return 0;
}
