package dev.idy.wgcne;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.net.VpnService;
import android.os.Looper;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.Robolectric;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.Shadows;
import org.robolectric.annotation.Config;
import org.robolectric.annotation.Implementation;
import org.robolectric.annotation.Implements;
import java.lang.reflect.Field;
import java.time.Duration;
import java.util.Collections;
import static org.junit.Assert.*;
import static org.mockito.Mockito.*;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 28, shadows = PluginConsentTest.ConsentVpn.class)
public class PluginConsentTest {
    @Implements(VpnService.class)
    public static class ConsentVpn {
        @Implementation public static Intent prepare(Context context) { return new Intent("test.VPN_CONSENT"); }
    }

    private WgcNePlugin plugin;
    private Activity activity;
    private ActivityPluginBinding activityBinding;

    private static final class Result implements MethodChannel.Result {
        int calls;
        String error;
        public void success(Object value) { calls++; }
        public void error(String code, String message, Object details) { calls++; error = code; }
        public void notImplemented() { fail(); }
    }

    private static void set(Object object, String name, Object value) throws Exception {
        Field field = object.getClass().getDeclaredField(name);
        field.setAccessible(true);
        field.set(object, value);
    }

    @Before public void setUp() throws Exception {
        plugin = new WgcNePlugin();
        set(plugin, "context", RuntimeEnvironment.getApplication());
        set(plugin, "service", mock(WgcVpnService.class));
        activity = Robolectric.buildActivity(Activity.class).setup().get();
        activityBinding = mock(ActivityPluginBinding.class);
        when(activityBinding.getActivity()).thenReturn(activity);
        plugin.onAttachedToActivity(activityBinding);
    }

    @After public void tearDown() { plugin.onDetachedFromEngine(null); }

    private Result start() {
        Result result = new Result();
        plugin.onMethodCall(new MethodCall("start", Collections.singletonMap("configuration", "{}")), result);
        return result;
    }

    private int requestCode() {
        return Shadows.shadowOf(activity).getNextStartedActivityForResult().requestCode;
    }

    @Test public void waitsForMatchingConsentAndReportsDenialOnce() {
        Result result = start();
        int code = requestCode();
        assertEquals(0, result.calls);
        assertFalse(plugin.onActivityResult(code + 1, Activity.RESULT_OK, null));
        assertTrue(plugin.onActivityResult(code, Activity.RESULT_CANCELED, null));
        assertEquals("permission_denied", result.error);
        assertEquals(1, result.calls);
        assertFalse(plugin.onActivityResult(code, Activity.RESULT_OK, null));
    }

    @Test public void lateConsentCannotCompleteANewerStart() {
        Result first = start();
        int oldCode = requestCode();
        Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(41));
        assertEquals("timeout", first.error);
        Result second = start();
        int newCode = requestCode();
        assertNotEquals(oldCode, newCode);
        assertFalse(plugin.onActivityResult(oldCode, Activity.RESULT_OK, null));
        assertEquals(0, second.calls);
        assertTrue(plugin.onActivityResult(newCode, Activity.RESULT_CANCELED, null));
        assertEquals("permission_denied", second.error);
    }

    @Test public void activityRotationRetainsPendingConsentButFinalDetachCancelsIt() {
        Result result = start();
        int code = requestCode();
        plugin.onDetachedFromActivityForConfigChanges();
        assertEquals(0, result.calls);
        plugin.onReattachedToActivityForConfigChanges(activityBinding);
        plugin.onDetachedFromActivity();
        assertEquals("cancelled", result.error);
        assertEquals(1, result.calls);
        assertFalse(plugin.onActivityResult(code, Activity.RESULT_OK, null));
    }

    @Test public void stopDuringConsentPreventsALateStart() {
        Result start = start();
        int code = requestCode();
        plugin.onMethodCall(new MethodCall("stop", Collections.emptyMap()), new Result());
        assertEquals("cancelled", start.error);
        assertFalse(plugin.onActivityResult(code, Activity.RESULT_OK, null));
        assertEquals(1, start.calls);
    }
}
