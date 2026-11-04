package dev.idy.wgcne;

import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;
import static org.junit.Assert.*;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 28)
public class CoreBridgeTest {
    @Test public void nativeErrorsNeverExposeMessagesOrUnknownCodes() throws Exception {
        for (String code : new String[]{"invalid_configuration", "private-error-detail"}) {
            try {
                CoreBridge.result("{\"ok\":false,\"error\":{\"code\":\"" + code +
                        "\",\"message\":\"private-key-material\"}}");
                fail();
            } catch (CoreBridge.Failure error) {
                assertEquals(code.equals("invalid_configuration") ? code : "core_failure", error.code);
                assertFalse(error.toString().contains("private"));
            }
        }
    }

    @Test public void rejectsMalformedEnvelopes() throws Exception {
        for (String raw : new String[]{"secret", "{}", "{\"ok\":true,\"result\":null}"}) {
            try { CoreBridge.result(raw); fail(); }
            catch (CoreBridge.Failure error) { assertEquals("invalid_response", error.code); }
        }
    }
}
