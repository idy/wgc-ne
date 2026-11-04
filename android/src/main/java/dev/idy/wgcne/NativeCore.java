package dev.idy.wgcne;

final class NativeCore {
    interface Protector {
        boolean protect(int fd);
    }

    static {
        System.loadLibrary("wgcne");
    }

    static native String validate(byte[] configuration);
    static native String start(int ownedFd, byte[] configuration, Protector protector);
    static native String status(long handle);
    static native void stop(long handle);

    private NativeCore() {}
}
