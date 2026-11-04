package dev.idy.wgcne;

import android.content.Intent;
import android.net.VpnService;
import android.os.Looper;
import android.os.ParcelFileDescriptor;
import org.json.JSONObject;
import org.json.JSONArray;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.Rule;
import org.junit.rules.TemporaryFolder;
import org.junit.runner.RunWith;
import org.robolectric.Robolectric;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.Shadows;
import org.robolectric.annotation.Config;
import org.robolectric.annotation.Implementation;
import org.robolectric.annotation.Implements;
import org.robolectric.annotation.RealObject;
import org.robolectric.annotation.LooperMode;
import java.net.InetAddress;
import org.robolectric.android.controller.ServiceController;
import org.robolectric.shadows.ShadowParcelFileDescriptor;
import org.robolectric.util.ReflectionHelpers;
import java.io.FileDescriptor;
import java.io.FileInputStream;
import java.io.IOException;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.function.BooleanSupplier;
import static org.junit.Assert.*;

@RunWith(RobolectricTestRunner.class)
@LooperMode(LooperMode.Mode.PAUSED)
@Config(sdk = 28, shadows = {ServiceLifecycleTest.TunBuilder.class, ServiceLifecycleTest.DescriptorShadow.class})
public class ServiceLifecycleTest {
    private ServiceController<WgcVpnService> controller;
    private WgcVpnService service;
    private FakeCore core;
    @Rule public TemporaryFolder files = new TemporaryFolder();
    private static ParcelFileDescriptor readEnd;
    private static ParcelFileDescriptor established;

    @Implements(VpnService.Builder.class)
    public static class TunBuilder {
        @RealObject private VpnService.Builder builder;
        // RouteInfo relies on Android-only InetAddress fields absent on the host
        // JVM. CIDR subtraction has separate real numeric-address tests.
        @Implementation protected VpnService.Builder addRoute(InetAddress address, int prefix) {
            if (address.isLoopbackAddress()) throw new IllegalArgumentException("Bad address");
            return builder;
        }
        @Implementation protected ParcelFileDescriptor establish() throws Exception {
            established = ParcelFileDescriptor.dup(readEnd.getFileDescriptor());
            return established;
        }
    }

    // Robolectric 4.14's static dup creates a raw descriptor without the
    // RandomAccessFile required by its getFd/close shadows. Model raw ownership
    // transfer explicitly; JNI and Go tests cover the real native FD boundary.
    @Implements(ParcelFileDescriptor.class)
    public static class DescriptorShadow extends ShadowParcelFileDescriptor {
        @Implementation protected int detachFd() {
            FileDescriptor descriptor = super.getFileDescriptor();
            int fd = ReflectionHelpers.getField(descriptor, "fd");
            ReflectionHelpers.setField(descriptor, "fd", -1);
            return fd;
        }
        @Implementation protected static ParcelFileDescriptor adoptFd(int fd) {
            FileDescriptor descriptor = new FileDescriptor();
            ReflectionHelpers.setField(descriptor, "fd", fd);
            return ReflectionHelpers.callConstructor(ParcelFileDescriptor.class,
                    ReflectionHelpers.ClassParameter.from(FileDescriptor.class, descriptor));
        }
        @Override @Implementation protected void close() throws IOException {
            FileDescriptor descriptor = super.getFileDescriptor();
            super.close();
            if (descriptor.valid()) new FileInputStream(descriptor).close();
        }
    }

    private static final class Reply implements WgcVpnService.Reply {
        int calls;
        String error;
        Map<String, Object> value;
        public void success(Map<String, Object> value) { calls++; this.value = value; }
        public void failure(String code) { calls++; error = code; }
    }

    private static final class FakeCore implements WgcVpnService.Core {
        final CountDownLatch entered = new CountDownLatch(1);
        final CountDownLatch release = new CountDownLatch(1);
        volatile int stops;
        volatile boolean failed;
        volatile boolean rejectConfiguration;
        volatile boolean block;
        boolean ipv6;
        String excludedRoute = "203.0.113.10/32";
        public JSONObject validate(String configuration) throws CoreBridge.Failure {
            if (rejectConfiguration) throw new CoreBridge.Failure("invalid_configuration");
            try {
                return new JSONObject().put("mtu", 1280)
                        .put("addresses", new JSONArray().put(ipv6 ? "2001:db8::2/128" : "10.7.0.2/32"))
                        .put("dns_servers", new JSONArray().put(ipv6 ? "2001:2::2" : "198.18.0.2"))
                        .put("included_routes", new JSONArray().put(ipv6 ? "::/0" : "0.0.0.0/0"))
                        .put("excluded_routes", new JSONArray().put(excludedRoute));
            } catch (Exception error) { throw new AssertionError(error); }
        }
        public long start(int fd, String configuration, NativeCore.Protector protector) {
            try (ParcelFileDescriptor owned = ParcelFileDescriptor.adoptFd(fd)) {
                entered.countDown();
                if (block && !release.await(3, TimeUnit.SECONDS)) throw new AssertionError("start stayed blocked");
                return 1;
            } catch (Exception error) { throw new AssertionError(error); }
        }
        public Map<String, Object> status(long handle) {
            Map<String, Object> value = new HashMap<>();
            value.put("state", failed ? "stopped" : "running");
            return value;
        }
        public void stop(long handle) {
            assertTrue("Core must close before the service-owned TUN", established.getFileDescriptor().valid());
            stops++;
        }
    }

    @Before public void setUp() throws Exception {
        readEnd = ParcelFileDescriptor.open(files.newFile("synthetic-tun"), ParcelFileDescriptor.MODE_READ_WRITE);
        established = null;
        controller = Robolectric.buildService(WgcVpnService.class).create();
        service = controller.get();
        core = new FakeCore();
        service.core = core;
    }

    @After public void tearDown() throws Exception {
        core.release.countDown();
        if (controller != null) {
            Reply stopped = new Reply();
            service.stopTunnel(stopped);
            await(() -> stopped.calls == 1);
            controller.destroy();
        }
        readEnd.close();
    }

    private void await(BooleanSupplier condition) throws Exception {
        long until = System.nanoTime() + TimeUnit.SECONDS.toNanos(4);
        while (!condition.getAsBoolean() && System.nanoTime() < until) {
            Shadows.shadowOf(Looper.getMainLooper()).idle();
            Thread.sleep(10);
        }
        Shadows.shadowOf(Looper.getMainLooper()).idle();
        assertTrue("Operation did not complete", condition.getAsBoolean());
    }

    private Reply start() {
        Reply reply = new Reply();
        service.startTunnel("synthetic-test-configuration", "Test VPN", reply);
        service.onStartCommand(new Intent().setAction(WgcVpnService.START), 0, 1);
        return reply;
    }

    @Test public void validationFailureCleansUpWithoutCreatingTun() throws Exception {
        core.rejectConfiguration = true;
        Reply reply = start();
        await(() -> reply.calls == 1);
        assertEquals("invalid_configuration", reply.error);
        assertNull(established);
        assertEquals("disconnected", service.snapshot().get("state"));
    }

    @Test public void cancellingBeforeStartDeliveryStillFulfillsForegroundContract() throws Exception {
        Reply start = new Reply();
        service.startTunnel("synthetic-test-configuration", "Test VPN", start);
        assertNotNull(Shadows.shadowOf(service).getLastForegroundNotification());
        Reply stop = new Reply();
        service.stopTunnel(stop);
        service.onStartCommand(new Intent().setAction(WgcVpnService.START), 0, 1);
        await(() -> stop.calls == 1);
        assertEquals("cancelled", start.error);
        assertEquals(1, start.calls);
        assertEquals(1, core.entered.getCount());
        assertNull(established);
        assertEquals("disconnected", service.snapshot().get("state"));
    }

    @Test public void stopDuringStartRetiresLateHandleAndClosesTun() throws Exception {
        core.block = true;
        Reply start = start();
        assertTrue(core.entered.await(3, TimeUnit.SECONDS));
        Reply stop = new Reply();
        service.stopTunnel(stop);
        assertEquals("cancelled", start.error);
        core.release.countDown();
        await(() -> stop.calls == 1);
        assertEquals(1, start.calls);
        assertEquals(1, core.stops);
        assertFalse(established.getFileDescriptor().valid());
        assertEquals("disconnected", stop.value.get("state"));
    }

    @Test public void clientDeadlineOnlyCancelsItsOwnPendingStart() throws Exception {
        core.block = true;
        Reply start = start();
        assertTrue(core.entered.await(3, TimeUnit.SECONDS));
        service.cancelStart(new Reply());
        assertEquals(0, start.calls);
        service.cancelStart(start);
        assertEquals("cancelled", start.error);
        core.release.countDown();
        await(() -> service.snapshot().get("state").equals("disconnected"));
        assertEquals(1, core.stops);
        assertEquals(1, start.calls);
    }

    @Test public void destroyDuringStartDoesNotPublishLateConnection() throws Exception {
        core.block = true;
        Reply start = start();
        assertTrue(core.entered.await(3, TimeUnit.SECONDS));
        controller.destroy(); controller = null;
        assertEquals("cancelled", start.error);
        core.release.countDown();
        await(() -> core.stops == 1);
        assertEquals(1, start.calls);
        assertEquals("disconnected", service.snapshot().get("state"));
        await(() -> !established.getFileDescriptor().valid());
    }

    @Test public void terminalCoreFailureStopsWithoutFlutterPolling() throws Exception {
        Reply start = start();
        await(() -> start.calls == 1);
        assertNull(start.error);
        assertEquals("connected", start.value.get("state"));
        core.failed = true;
        await(() -> service.snapshot().get("state").equals("disconnected"));
        assertEquals(1, core.stops);
        assertFalse(established.getFileDescriptor().valid());
    }

    @Test public void publicPeerAdjacentToLoopbackStartsNormally() throws Exception {
        core.excludedRoute = "126.1.2.3/32";
        Reply start = start();
        await(() -> start.calls == 1);
        assertNull(start.error);
        assertEquals("connected", start.value.get("state"));
    }

    @Test public void ipv6ExclusionGeneratingLoopbackStartsNormally() throws Exception {
        core.ipv6 = true;
        core.excludedRoute = "::/128";
        Reply start = start();
        await(() -> start.calls == 1);
        assertNull(start.error);
        assertEquals("connected", start.value.get("state"));
    }

    @Test public void coldDisconnectIntentDoesNotLeaveAnIdleStartedService() {
        service.onStartCommand(new Intent().setAction(WgcVpnService.STOP), 0, 1);
        assertTrue(Shadows.shadowOf(service).isStoppedBySelf());
        assertEquals("disconnected", service.snapshot().get("state"));
    }

    @Test @Config(sdk = 23) public void revokeStopsTunnelAndRepeatedStopIsIdempotent() throws Exception {
        Reply start = start();
        await(() -> start.calls == 1);
        Thread binder = new Thread(service::onRevoke);
        binder.start();
        binder.join();
        assertEquals("connected", service.snapshot().get("state"));
        await(() -> service.snapshot().get("state").equals("disconnected"));
        Reply stop = new Reply();
        service.stopTunnel(stop);
        assertEquals("disconnected", stop.value.get("state"));
        assertEquals(1, core.stops);
    }
}
