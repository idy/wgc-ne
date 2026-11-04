package dev.idy.wgcne;

import android.os.ParcelFileDescriptor;
import org.json.JSONException;
import org.json.JSONObject;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.HashMap;
import java.util.Map;

final class CoreBridge {
    static final int MAX_CONFIGURATION_BYTES = 128 * 1024;

    static final class Failure extends Exception {
        final String code;
        Failure(String code) { this.code = code; }
    }

    static JSONObject validate(String configuration) throws Failure {
        byte[] bytes = configuration.getBytes(StandardCharsets.UTF_8);
        try {
            if (bytes.length == 0 || bytes.length > MAX_CONFIGURATION_BYTES) {
                throw new Failure("invalid_configuration");
            }
            return result(NativeCore.validate(bytes));
        } catch (LinkageError error) {
            throw new Failure("core_unavailable");
        } finally {
            Arrays.fill(bytes, (byte) 0);
        }
    }

    // The JNI start owns fd on all paths. If the symbol cannot be resolved,
    // Java still owns it and must close it here.
    static long start(int fd, String configuration, NativeCore.Protector protector) throws Failure {
        byte[] bytes = configuration.getBytes(StandardCharsets.UTF_8);
        try {
            long handle = result(NativeCore.start(fd, bytes, protector)).getLong("handle");
            if (handle <= 0) throw new Failure("core_failure");
            return handle;
        } catch (LinkageError error) {
            try (ParcelFileDescriptor ignored = ParcelFileDescriptor.adoptFd(fd)) {
                // close the descriptor that never reached JNI
            } catch (IOException ignored) {}
            throw new Failure("core_unavailable");
        } catch (JSONException error) {
            throw new Failure("invalid_response");
        } finally {
            Arrays.fill(bytes, (byte) 0);
        }
    }

    static Map<String, Object> status(long handle) throws Failure {
        JSONObject value = result(NativeCore.status(handle));
        Map<String, Object> status = new HashMap<>();
        try {
            String state = value.getString("state");
            if (!state.equals("running") && !state.equals("stopped")) {
                throw new Failure("invalid_response");
            }
            status.put("state", state);
            status.put("public_key", value.getString("public_key"));
            status.put("core_version", value.getString("core_version"));
            for (String key : new String[]{"bytes_sent", "bytes_received", "packets_sent", "packets_received"}) {
                long counter = value.getLong(key);
                if (counter < 0) throw new Failure("invalid_response");
                status.put(key, counter);
            }
            return status;
        } catch (JSONException error) {
            throw new Failure("invalid_response");
        }
    }

    static JSONObject result(String raw) throws Failure {
        try {
            JSONObject envelope = new JSONObject(raw);
            if (!envelope.getBoolean("ok")) {
                String code = envelope.getJSONObject("error").optString("code");
                throw new Failure(code.equals("invalid_configuration") ? code : "core_failure");
            }
            return envelope.getJSONObject("result");
        } catch (JSONException | NullPointerException error) {
            throw new Failure("invalid_response");
        }
    }

    private CoreBridge() {}
}
