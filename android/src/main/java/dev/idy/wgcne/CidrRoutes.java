package dev.idy.wgcne;

import java.math.BigInteger;
import java.net.InetAddress;
import java.net.UnknownHostException;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

// Subtraction preserves excluded routes on Android 6-12, which have no
// VpnService.Builder.excludeRoute. Inputs come from the validated native core.
final class CidrRoutes {
    static final int MAX_ROUTES = 8192;
    final BigInteger address;
    final int prefix;
    final int bits;

    private CidrRoutes(BigInteger address, int prefix, int bits) {
        this.bits = bits;
        this.prefix = prefix;
        this.address = address.shiftRight(bits - prefix).shiftLeft(bits - prefix);
    }

    static CidrRoutes parse(String cidr) throws CoreBridge.Failure {
        try {
            String[] parts = cidr.split("/", -1);
            if (parts.length != 2 || !parts[0].matches("[0-9a-fA-F:.]+")) {
                throw new IllegalArgumentException();
            }
            byte[] address = InetAddress.getByName(parts[0]).getAddress();
            int prefix = Integer.parseInt(parts[1]);
            if (prefix < 0 || prefix > address.length * 8) throw new IllegalArgumentException();
            return new CidrRoutes(new BigInteger(1, address), prefix, address.length * 8);
        } catch (IllegalArgumentException | UnknownHostException error) {
            throw new CoreBridge.Failure("invalid_configuration");
        }
    }

    boolean contains(CidrRoutes other) {
        return bits == other.bits && prefix <= other.prefix &&
                address.equals(other.address.shiftRight(bits - prefix).shiftLeft(bits - prefix));
    }

    private void subtract(CidrRoutes excluded, List<CidrRoutes> result) throws CoreBridge.Failure {
        if (excluded.contains(this)) return;
        if (!contains(excluded)) {
            result.add(this);
            if (result.size() > MAX_ROUTES) throw new CoreBridge.Failure("invalid_configuration");
            return;
        }
        int childPrefix = prefix + 1;
        new CidrRoutes(address, childPrefix, bits).subtract(excluded, result);
        new CidrRoutes(address.setBit(bits - childPrefix), childPrefix, bits).subtract(excluded, result);
    }

    static List<CidrRoutes> subtract(List<String> included, List<String> excluded) throws CoreBridge.Failure {
        List<CidrRoutes> routes = new ArrayList<>();
        Set<String> unique = new LinkedHashSet<>(included);
        for (String value : unique) routes.add(parse(value));
        for (String value : new LinkedHashSet<>(excluded)) {
            CidrRoutes exclusion = parse(value);
            List<CidrRoutes> remaining = new ArrayList<>();
            for (CidrRoutes route : routes) route.subtract(exclusion, remaining);
            routes = remaining;
        }
        return routes;
    }

    InetAddress inetAddress() throws UnknownHostException {
        byte[] encoded = address.toByteArray();
        byte[] bytes = new byte[bits / 8];
        int length = Math.min(bytes.length, encoded.length);
        System.arraycopy(encoded, encoded.length - length, bytes, bytes.length - length, length);
        return InetAddress.getByAddress(bytes);
    }
}
