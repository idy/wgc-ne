package dev.idy.wgcne;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.net.VpnService;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;

public final class WgcNePlugin implements FlutterPlugin, ActivityAware,
        MethodChannel.MethodCallHandler, PluginRegistry.ActivityResultListener {
    private static final AtomicInteger consentCodes = new AtomicInteger(0x1747);
    // Flutter engines in this app share the same VPN service and pending start.
    private static OnceReply pendingStart;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final List<Bound> waiting = new ArrayList<>();
    private final Set<OnceReply> replies = new HashSet<>();
    private Context context;
    private MethodChannel channel;
    private ActivityPluginBinding activityBinding;
    private WgcVpnService service;
    private boolean binding;
    private Consent consent;
    private final Runnable bindDeadline = () -> lostService("timeout");

    private interface Bound { void run(WgcVpnService service); }
    private static final class Consent {
        final String configuration;
        final String label;
        final OnceReply reply;
        final int requestCode = 0x4000 | (consentCodes.getAndIncrement() & 0x3fff);
        Consent(String configuration, String label, OnceReply reply) {
            this.configuration = configuration;
            this.label = label;
            this.reply = reply;
        }
    }

    private final ServiceConnection connection = new ServiceConnection() {
        @Override public void onServiceConnected(ComponentName name, IBinder binder) {
            if (!(binder instanceof WgcVpnService.LocalBinder)) {
                lostService("provider_unavailable");
                return;
            }
            main.removeCallbacks(bindDeadline);
            service = ((WgcVpnService.LocalBinder) binder).service();
            List<Bound> ready = new ArrayList<>(waiting);
            waiting.clear();
            for (Bound operation : ready) operation.run(service);
        }
        @Override public void onServiceDisconnected(ComponentName name) { lostService("provider_unavailable"); }
        @Override public void onBindingDied(ComponentName name) { lostService("provider_unavailable"); }
        @Override public void onNullBinding(ComponentName name) { lostService("provider_unavailable"); }
    };

    @Override public void onAttachedToEngine(FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        channel = new MethodChannel(binding.getBinaryMessenger(), "dev.idy.wgc_ne/methods");
        channel.setMethodCallHandler(this);
    }

    @Override public void onMethodCall(MethodCall call, MethodChannel.Result result) {
        if (!call.method.equals("start") && !call.method.equals("stop") &&
                !call.method.equals("status") && !call.method.equals("removeProfile")) {
            result.notImplemented();
            return;
        }
        OnceReply reply = new OnceReply(result);
        if (context == null) { reply.failure("provider_unavailable"); return; }
        if (!(call.arguments instanceof Map)) { reply.failure("invalid_arguments"); return; }
        if (call.method.equals("start")) {
            Object raw = call.argument("configuration");
            Object description = call.argument("localizedDescription");
            if (!(raw instanceof String) || (description != null && !(description instanceof String))) {
                reply.failure("invalid_arguments"); return;
            }
            String configuration = (String) raw;
            String label = description == null ? "WGC NE" : (String) description;
            if (configuration.isEmpty() || configuration.length() > CoreBridge.MAX_CONFIGURATION_BYTES ||
                    configuration.getBytes(StandardCharsets.UTF_8).length > CoreBridge.MAX_CONFIGURATION_BYTES) {
                reply.failure("invalid_configuration"); return;
            }
            if (label.isEmpty() || label.length() > 255) { reply.failure("invalid_arguments"); return; }
            if (pendingStart != null) { reply.failure("profile_conflict"); return; }
            pendingStart = reply;
            ensureBound(bound -> {
                if (!reply.isDone()) prepare(configuration, label, reply);
            });
        } else {
            if (!call.method.equals("status") && pendingStart != null) {
                pendingStart.failure("cancelled");
            }
            ensureBound(bound -> {
                if (reply.isDone()) return;
                if (call.method.equals("status")) reply.success(bound.snapshot());
                else bound.stopTunnel(reply);
            });
        }
    }

    private void ensureBound(Bound operation) {
        if (service != null) { operation.run(service); return; }
        waiting.add(operation);
        if (binding) return;
        try {
            binding = context.bindService(new Intent(context, WgcVpnService.class).setAction(WgcVpnService.BIND),
                    connection, Context.BIND_AUTO_CREATE);
            if (!binding) lostService("provider_unavailable");
            else main.postDelayed(bindDeadline, 10_000);
        } catch (RuntimeException error) { lostService("provider_unavailable"); }
    }

    private void prepare(String configuration, String label, OnceReply reply) {
        if (consent != null) { reply.failure("profile_conflict"); return; }
        Activity activity = activityBinding == null ? null : activityBinding.getActivity();
        if (activity == null || activity.isFinishing()) { reply.failure("provider_unavailable"); return; }
        try {
            Intent intent = VpnService.prepare(activity);
            if (intent == null) service.startTunnel(configuration, label, reply);
            else {
                consent = new Consent(configuration, label, reply);
                activity.startActivityForResult(intent, consent.requestCode);
            }
        } catch (RuntimeException error) {
            consent = null;
            reply.failure("tunnel_start_failed");
        }
    }

    @Override public boolean onActivityResult(int requestCode, int resultCode, Intent data) {
        if (consent == null || requestCode != consent.requestCode) return false;
        Consent request = consent;
        consent = null;
        if (request.reply.isDone()) return true;
        if (resultCode != Activity.RESULT_OK) request.reply.failure("permission_denied");
        else if (service == null) request.reply.failure("provider_unavailable");
        else service.startTunnel(request.configuration, request.label, request.reply);
        return true;
    }

    private void lostService(String code) {
        main.removeCallbacks(bindDeadline);
        waiting.clear();
        service = null;
        consent = null;
        if (binding && context != null) {
            try { context.unbindService(connection); } catch (IllegalArgumentException ignored) {}
        }
        binding = false;
        for (OnceReply reply : new ArrayList<>(replies)) reply.failure(code);
    }

    private final class OnceReply implements WgcVpnService.Reply {
        private MethodChannel.Result result;
        private final Runnable timeout = () -> {
            failure("timeout");
            if (service != null) service.cancelStart(this);
        };
        OnceReply(MethodChannel.Result result) {
            this.result = result;
            replies.add(this);
            main.postDelayed(timeout, 40_000);
        }
        boolean isDone() { return result == null; }
        private MethodChannel.Result take() {
            MethodChannel.Result value = result;
            if (value == null) return null;
            result = null;
            main.removeCallbacks(timeout);
            replies.remove(this);
            if (pendingStart == this) pendingStart = null;
            if (consent != null && consent.reply == this) consent = null;
            return value;
        }
        @Override public void success(Map<String, Object> value) {
            MethodChannel.Result target = take();
            if (target != null) target.success(value);
        }
        @Override public void failure(String code) {
            MethodChannel.Result target = take();
            if (target != null) target.error(code, "The tunnel operation could not be completed.", null);
        }
    }

    @Override public void onAttachedToActivity(ActivityPluginBinding binding) {
        activityBinding = binding;
        binding.addActivityResultListener(this);
    }
    private void detachActivity(boolean changingConfiguration) {
        if (activityBinding != null) activityBinding.removeActivityResultListener(this);
        activityBinding = null;
        if (!changingConfiguration && consent != null) {
            Consent request = consent;
            consent = null;
            request.reply.failure("cancelled");
        }
    }
    @Override public void onDetachedFromActivityForConfigChanges() { detachActivity(true); }
    @Override public void onReattachedToActivityForConfigChanges(ActivityPluginBinding binding) { onAttachedToActivity(binding); }
    @Override public void onDetachedFromActivity() { detachActivity(false); }

    @Override public void onDetachedFromEngine(FlutterPluginBinding binding) {
        detachActivity(false);
        if (channel != null) channel.setMethodCallHandler(null);
        channel = null;
        lostService("cancelled");
        context = null;
    }
}
