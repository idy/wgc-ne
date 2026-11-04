package dev.idy.wgcne;

import java.math.BigInteger;
import java.net.InetAddress;
import java.net.Inet6Address;
import java.net.UnknownHostException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

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
            byte[] address = parseAddress(parts[0]);
            int prefix = Integer.parseInt(parts[1]);
            if (prefix < 0 || prefix > address.length * 8) throw new IllegalArgumentException();
            return new CidrRoutes(new BigInteger(1, address), prefix, address.length * 8);
        } catch (IllegalArgumentException error) {
            throw new CoreBridge.Failure("invalid_configuration");
        }
    }

    private static byte[] parseAddress(String value) {
        // Parse literals locally: even malformed input must never trigger DNS.
        if (value.indexOf(':') < 0) return parseIpv4(value);
        if (value.indexOf('.') >= 0) {
            int lastColon = value.lastIndexOf(':');
            byte[] ipv4 = parseIpv4(value.substring(lastColon + 1));
            value = value.substring(0, lastColon + 1) +
                    Integer.toHexString(((ipv4[0] & 255) << 8) | (ipv4[1] & 255)) + ":" +
                    Integer.toHexString(((ipv4[2] & 255) << 8) | (ipv4[3] & 255));
        }
        int compression = value.indexOf("::");
        if (compression != value.lastIndexOf("::")) throw new IllegalArgumentException();
        String head = compression < 0 ? value : value.substring(0, compression);
        String tail = compression < 0 ? "" : value.substring(compression + 2);
        String[] left = head.isEmpty() ? new String[0] : head.split(":", -1);
        String[] right = tail.isEmpty() ? new String[0] : tail.split(":", -1);
        int words = left.length + right.length;
        if (compression < 0 ? words != 8 : words >= 8) throw new IllegalArgumentException();
        byte[] bytes = new byte[16];
        writeIpv6Words(left, bytes, 0);
        writeIpv6Words(right, bytes, bytes.length - right.length * 2);
        return bytes;
    }

    private static void writeIpv6Words(String[] words, byte[] bytes, int offset) {
        for (String word : words) {
            if (word.isEmpty() || word.length() > 4) throw new IllegalArgumentException();
            int value = Integer.parseInt(word, 16);
            bytes[offset++] = (byte) (value >> 8);
            bytes[offset++] = (byte) value;
        }
    }

    private static byte[] parseIpv4(String value) {
        String[] octets = value.split("\\.", -1);
        if (octets.length != 4) throw new IllegalArgumentException();
        byte[] bytes = new byte[4];
        for (int index = 0; index < octets.length; index++) {
            if (octets[index].isEmpty() || octets[index].length() > 3) throw new IllegalArgumentException();
            int octet = Integer.parseInt(octets[index]);
            if (octet < 0 || octet > 255) throw new IllegalArgumentException();
            bytes[index] = (byte) octet;
        }
        return bytes;
    }

    boolean contains(CidrRoutes other) {
        return bits == other.bits && prefix <= other.prefix &&
                address.equals(other.address.shiftRight(bits - prefix).shiftLeft(bits - prefix));
    }

    // Half-open ranges also represent the exclusive upper bounds 2^32 and 2^128.
    private static final class Range {
        final BigInteger start;
        final BigInteger end;

        Range(BigInteger start, BigInteger end) {
            this.start = start;
            this.end = end;
        }
    }

    private static List<CidrRoutes> parseAll(List<String> values) throws CoreBridge.Failure {
        List<CidrRoutes> routes = new ArrayList<>();
        for (String value : values) routes.add(parse(value));
        return routes;
    }

    private static List<Range> union(List<CidrRoutes> routes, int bits) {
        List<Range> ranges = new ArrayList<>();
        for (CidrRoutes route : routes) {
            if (route.bits == bits) {
                ranges.add(new Range(route.address,
                        route.address.add(BigInteger.ONE.shiftLeft(bits - route.prefix))));
            }
        }
        Collections.sort(ranges, (left, right) -> left.start.compareTo(right.start));
        List<Range> merged = new ArrayList<>();
        for (Range range : ranges) {
            if (!merged.isEmpty()) {
                Range previous = merged.get(merged.size() - 1);
                if (range.start.compareTo(previous.end) <= 0) {
                    merged.set(merged.size() - 1, new Range(previous.start, previous.end.max(range.end)));
                    continue;
                }
            }
            merged.add(range);
        }
        return merged;
    }

    private static void appendRange(BigInteger start, BigInteger end, int bits,
                                    List<CidrRoutes> result) throws CoreBridge.Failure {
        while (start.compareTo(end) < 0) {
            int alignment = start.signum() == 0 ? bits : start.getLowestSetBit();
            int blockBits = Math.min(alignment, end.subtract(start).bitLength() - 1);
            // Both unions are complete before emitting these minimal, disjoint
            // CIDRs, so this limit applies only to the final canonical result.
            if (result.size() == MAX_ROUTES) throw new CoreBridge.Failure("invalid_configuration");
            result.add(new CidrRoutes(start, bits - blockBits, bits));
            start = start.add(BigInteger.ONE.shiftLeft(blockBits));
        }
    }

    private static void subtractRanges(List<Range> included, List<Range> excluded, int bits,
                                       List<CidrRoutes> result) throws CoreBridge.Failure {
        int exclusionIndex = 0;
        for (Range range : included) {
            BigInteger start = range.start;
            while (exclusionIndex < excluded.size() &&
                    excluded.get(exclusionIndex).end.compareTo(start) <= 0) {
                exclusionIndex++;
            }
            while (exclusionIndex < excluded.size()) {
                Range exclusion = excluded.get(exclusionIndex);
                if (exclusion.start.compareTo(range.end) >= 0) break;
                if (start.compareTo(exclusion.start) < 0) {
                    appendRange(start, exclusion.start, bits, result);
                }
                start = start.max(exclusion.end);
                // Keep an exclusion that may also cover the next include range.
                if (start.compareTo(range.end) >= 0) break;
                exclusionIndex++;
            }
            appendRange(start, range.end, bits, result);
        }
    }

    static List<CidrRoutes> subtract(List<String> included, List<String> excluded) throws CoreBridge.Failure {
        List<CidrRoutes> includes = parseAll(included);
        List<CidrRoutes> excludes = parseAll(excluded);
        List<CidrRoutes> result = new ArrayList<>();
        for (int bits : new int[] {32, 128}) {
            subtractRanges(union(includes, bits), union(excludes, bits), bits, result);
        }
        return result;
    }

    InetAddress inetAddress() throws UnknownHostException {
        byte[] encoded = address.toByteArray();
        byte[] bytes = new byte[bits / 8];
        int length = Math.min(bytes.length, encoded.length);
        System.arraycopy(encoded, encoded.length - length, bytes, bytes.length - length, length);
        return bits == 128 ? Inet6Address.getByAddress(null, bytes, -1) : InetAddress.getByAddress(bytes);
    }
}
