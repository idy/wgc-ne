package dev.idy.wgcne;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.net.VpnService;
import android.os.Binder;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.ParcelFileDescriptor;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.IOException;
import java.net.InetAddress;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.ScheduledThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

/** Owns the tunnel independently of Flutter activities and engines. */
public final class WgcVpnService extends VpnService {
    static final String BIND = "dev.idy.wgcne.BIND";
    static final String START = "dev.idy.wgcne.START";
    static final String STOP = "dev.idy.wgcne.STOP";
    private static final String CHANNEL = "dev.idy.wgcne.vpn";
    private static final int NOTIFICATION = 0x574743;

    interface Reply {
        void success(Map<String, Object> value);
        void failure(String code);
    }

    interface Core {
        JSONObject validate(String configuration) throws CoreBridge.Failure;
        long start(int ownedFd, String configuration, NativeCore.Protector protector) throws CoreBridge.Failure;
        Map<String, Object> status(long handle) throws CoreBridge.Failure;
        void stop(long handle);
    }

    Core core = new Core() {
        public JSONObject validate(String configuration) throws CoreBridge.Failure { return CoreBridge.validate(configuration); }
        public long start(int fd, String configuration, NativeCore.Protector protector) throws CoreBridge.Failure {
            return CoreBridge.start(fd, configuration, protector);
        }
        public Map<String, Object> status(long handle) throws CoreBridge.Failure { return CoreBridge.status(handle); }
        public void stop(long handle) { NativeCore.stop(handle); }
    };

    final class LocalBinder extends Binder {
        WgcVpnService service() { return WgcVpnService.this; }
    }

    private final Handler main = new Handler(Looper.getMainLooper());
    private final AtomicLong generation = new AtomicLong();
    private final ScheduledThreadPoolExecutor worker = new ScheduledThreadPoolExecutor(1, runnable -> {
        Thread thread = new Thread(runnable, "wgc-ne-core");
        thread.setDaemon(true);
        return thread;
    });
    private String state = "disconnected";
    private Map<String, Object> coreStatus;
    private Reply startReply;
    private StartRequest pending;
    private Runnable deadline;
    private volatile boolean destroyed;
    // Only the worker touches native handles, TUN ownership and health polling.
    private long handle;
    private ParcelFileDescriptor tunnel;
    private ScheduledFuture<?> health;

    private static final class StartRequest {
        final long generation;
        final String configuration;
        final String label;
        StartRequest(long generation, String configuration, String label) {
            this.generation = generation;
            this.configuration = configuration;
            this.label = label;
        }
    }

    @Override public void onCreate() {
        super.onCreate();
        worker.setRemoveOnCancelPolicy(true);
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationChannel channel = new NotificationChannel(CHANNEL,
                    getString(R.string.wgc_ne_channel), NotificationManager.IMPORTANCE_LOW);
            getSystemService(NotificationManager.class).createNotificationChannel(channel);
        }
    }

    @Override public IBinder onBind(Intent intent) {
        return BIND.equals(intent.getAction()) ? new LocalBinder() : super.onBind(intent);
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && STOP.equals(intent.getAction())) {
            stopTunnel(null);
        } else if (intent != null && START.equals(intent.getAction()) && pending != null) {
            StartRequest request = pending;
            pending = null;
            try {
                worker.execute(() -> open(request));
            } catch (RuntimeException error) {
                failStart(request.generation, "tunnel_start_failed");
            }
        } else if (state.equals("disconnected")) {
            stopSelf(startId);
        }
        // Configuration is deliberately memory-only; never restart without it.
        return START_NOT_STICKY;
    }

    void startTunnel(String configuration, String label, Reply reply) {
        if (destroyed) { reply.failure("provider_unavailable"); return; }
        if (!state.equals("disconnected")) { reply.failure("profile_conflict"); return; }
        long token = generation.incrementAndGet();
        state = "connecting";
        coreStatus = null;
        startReply = reply;
        pending = new StartRequest(token, configuration, label);
        deadline = () -> {
            if (current(token) && startReply != null) {
                finishStart("timeout");
                stopTunnel(null);
            }
        };
        main.postDelayed(deadline, 35_000);
        Intent intent = new Intent(this, WgcVpnService.class).setAction(START);
        try {
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent);
            else startService(intent);
            // Binding keeps this service alive after stopSelf, so fulfill the
            // foreground contract before a later stop can cancel the START intent.
            foreground(label, false);
        } catch (RuntimeException error) {
            failStart(token, "tunnel_start_failed");
        }
    }

    private boolean current(long token) { return !destroyed && generation.get() == token; }

    private void open(StartRequest request) {
        try {
            if (!current(request.generation)) return;
            JSONObject settings = core.validate(request.configuration);
            Builder builder = new Builder().setSession(request.label).setMtu(settings.getInt("mtu"))
                    .setBlocking(false).setUnderlyingNetworks(null);
            for (String value : strings(settings.getJSONArray("addresses"))) {
                String[] parts = value.split("/", -1);
                builder.addAddress(InetAddress.getByName(parts[0]), Integer.parseInt(parts[1]));
            }
            for (String value : strings(settings.getJSONArray("dns_servers"))) {
                builder.addDnsServer(InetAddress.getByName(value));
            }
            List<CidrRoutes> routes = CidrRoutes.subtract(strings(settings.getJSONArray("included_routes")),
                    strings(settings.getJSONArray("excluded_routes")));
            for (CidrRoutes route : routes) {
                InetAddress address = route.inetAddress();
                if (!address.isLoopbackAddress()) builder.addRoute(address, route.prefix);
            }
            if (Build.VERSION.SDK_INT >= 29) builder.setMetered(false);
            if (!current(request.generation)) return;
            tunnel = builder.establish();
            if (tunnel == null) throw new CoreBridge.Failure("permission_denied");
            if (!current(request.generation)) { cleanup(); return; }
            int ownedFd;
            try (ParcelFileDescriptor duplicate = ParcelFileDescriptor.dup(tunnel.getFileDescriptor())) {
                ownedFd = duplicate.detachFd();
            }
            handle = core.start(ownedFd, request.configuration, this::protectSocket);
            if (!current(request.generation)) { cleanup(); return; }
            Map<String, Object> initial = core.status(handle);
            if (!"running".equals(initial.get("state"))) throw new CoreBridge.Failure("core_failure");
            final long token = request.generation;
            health = worker.scheduleWithFixedDelay(() -> poll(token), 1, 1, TimeUnit.SECONDS);
            main.post(() -> {
                if (current(request.generation)) {
                    coreStatus = initial;
                    state = "connected";
                    try { foreground(request.label, true); } catch (RuntimeException ignored) {}
                    finishStart(null);
                }
            });
        } catch (CoreBridge.Failure error) {
            cleanup();
            main.post(() -> failStart(request.generation, error.code));
        } catch (Exception | LinkageError error) {
            cleanup();
            main.post(() -> failStart(request.generation, "tunnel_start_failed"));
        }
    }

    private boolean protectSocket(int fd) {
        try { return !destroyed && protect(fd); }
        catch (RuntimeException error) { return false; }
    }

    private void poll(long token) {
        if (!current(token) || handle == 0) return;
        try {
            Map<String, Object> value = core.status(handle);
            if (!"running".equals(value.get("state"))) throw new CoreBridge.Failure("core_failure");
            main.post(() -> { if (current(token)) coreStatus = value; });
        } catch (Exception | LinkageError error) {
            main.post(() -> { if (current(token)) stopTunnel(null); });
        }
    }

    void cancelStart(Reply expected) {
        if (startReply == expected) stopTunnel(null);
    }

    void stopTunnel(Reply reply) {
        if (destroyed) { if (reply != null) reply.failure("provider_unavailable"); return; }
        if (state.equals("disconnected")) {
            dismissForeground();
            stopSelf();
            if (reply != null) reply.success(snapshot());
            return;
        }
        long token = generation.incrementAndGet();
        pending = null;
        finishStart("cancelled");
        state = "disconnecting";
        worker.execute(() -> {
            cleanup();
            main.post(() -> {
                if (current(token)) {
                    state = "disconnected";
                    coreStatus = null;
                    dismissForeground();
                    stopSelf();
                }
                if (reply != null) reply.success(snapshot());
            });
        });
    }

    Map<String, Object> snapshot() {
        Map<String, Object> value = new HashMap<>();
        value.put("state", state);
        if (coreStatus != null) value.put("core", new HashMap<>(coreStatus));
        return value;
    }

    private void finishStart(String error) {
        if (deadline != null) main.removeCallbacks(deadline);
        deadline = null;
        Reply reply = startReply;
        startReply = null;
        if (reply != null) {
            if (error == null) reply.success(snapshot());
            else reply.failure(error);
        }
    }

    private void failStart(long token, String code) {
        if (!current(token)) return;
        pending = null;
        state = "disconnected";
        coreStatus = null;
        finishStart(code);
        dismissForeground();
        stopSelf();
    }

    private void cleanup() {
        if (health != null) health.cancel(false);
        health = null;
        if (handle != 0) {
            try { core.stop(handle); } catch (RuntimeException | LinkageError ignored) {}
            handle = 0;
        }
        if (tunnel != null) {
            try { tunnel.close(); } catch (IOException ignored) {}
            tunnel = null;
        }
    }

    private void dismissForeground() {
        if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE);
        else stopForeground(true);
    }

    private void foreground(String label, boolean connected) {
        Intent stop = new Intent(this, WgcVpnService.class).setAction(STOP);
        PendingIntent disconnect = PendingIntent.getService(this, 0, stop,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        Notification.Builder builder = Build.VERSION.SDK_INT >= 26 ?
                new Notification.Builder(this, CHANNEL) : new Notification.Builder(this);
        builder.setSmallIcon(R.drawable.ic_wgc_ne_vpn).setContentTitle(label)
                .setContentText(getString(connected ? R.string.wgc_ne_connected : R.string.wgc_ne_connecting))
                .setOngoing(true).setOnlyAlertOnce(true).setCategory(Notification.CATEGORY_SERVICE)
                .addAction(new Notification.Action.Builder(null, getString(R.string.wgc_ne_disconnect), disconnect).build());
        Intent launch = getPackageManager().getLaunchIntentForPackage(getPackageName());
        if (launch != null) builder.setContentIntent(PendingIntent.getActivity(this, 0, launch,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE));
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION, builder.build(), ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED);
        } else startForeground(NOTIFICATION, builder.build());
    }

    private static List<String> strings(JSONArray values) throws Exception {
        List<String> result = new ArrayList<>();
        for (int index = 0; index < values.length(); index++) result.add(values.getString(index));
        return result;
    }

    @Override public void onRevoke() {
        // Android can invoke revocation on a Binder thread.
        main.post(() -> stopTunnel(null));
    }

    @Override public void onDestroy() {
        destroyed = true;
        generation.incrementAndGet();
        pending = null;
        finishStart("cancelled");
        worker.execute(this::cleanup);
        worker.shutdown();
        state = "disconnected";
        coreStatus = null;
        dismissForeground();
        super.onDestroy();
    }
}
