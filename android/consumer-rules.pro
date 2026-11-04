# JNI entry points and the callback invoked from arbitrary Go threads.
-keep class dev.idy.wgcne.NativeCore { *; }
-keep interface dev.idy.wgcne.NativeCore$Protector { *; }
-keepclassmembers class * implements dev.idy.wgcne.NativeCore$Protector {
    public boolean protect(int);
}
