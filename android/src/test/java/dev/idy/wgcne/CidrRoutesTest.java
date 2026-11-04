package dev.idy.wgcne;

import org.junit.Test;
import java.math.BigInteger;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import static org.junit.Assert.*;

public class CidrRoutesTest {
    private static boolean captures(List<CidrRoutes> routes, String address) throws Exception {
        CidrRoutes host = CidrRoutes.parse(address);
        for (CidrRoutes route : routes) if (route.contains(host)) return true;
        return false;
    }

    private static List<String> routeKeys(List<CidrRoutes> routes) {
        List<String> keys = new ArrayList<>();
        for (CidrRoutes route : routes) {
            keys.add(route.bits + ":" + route.address.toString(16) + "/" + route.prefix);
        }
        return keys;
    }

    private static void assertRoutes(List<CidrRoutes> routes, String... expected) throws Exception {
        List<CidrRoutes> prefixes = new ArrayList<>();
        for (String value : expected) prefixes.add(CidrRoutes.parse(value));
        assertEquals(routeKeys(prefixes), routeKeys(routes));
        assertCanonical(routes);
    }

    private static void assertCanonical(List<CidrRoutes> routes) throws Exception {
        CidrRoutes previous = null;
        for (CidrRoutes route : routes) {
            assertEquals(route.bits / 8, route.inetAddress().getAddress().length);
            if (previous != null) {
                assertTrue(previous.bits <= route.bits);
                if (previous.bits == route.bits) {
                    BigInteger end = previous.address.add(BigInteger.ONE.shiftLeft(previous.bits - previous.prefix));
                    assertTrue("Routes must be sorted and disjoint", end.compareTo(route.address) <= 0);
                    if (previous.prefix == route.prefix && route.prefix > 0) {
                        int parentBits = route.bits - route.prefix + 1;
                        assertFalse("Sibling prefixes must be merged",
                                previous.address.shiftRight(parentBits).equals(route.address.shiftRight(parentBits)));
                    }
                }
            }
            previous = route;
        }
    }

    private static List<String> dispersedIpv6Hosts(int count) {
        List<String> hosts = new ArrayList<>();
        for (int index = 0; index < count; index++) {
            // An odd, widely spaced step disperses hosts throughout 2001:db8::/32.
            hosts.add("2001:db8:" + Integer.toHexString((index * 40503) & 0xffff) + "::1/128");
        }
        return hosts;
    }

    private static void assertRouteLimit(List<String> included, List<String> excluded) throws Exception {
        try {
            CidrRoutes.subtract(included, excluded);
            fail("Expected the final canonical route set to exceed the limit");
        } catch (CoreBridge.Failure error) {
            assertEquals("invalid_configuration", error.code);
        }
    }

    @Test public void ipv4ExclusionsRemoveOnlyTheirAddresses() throws Exception {
        List<CidrRoutes> routes = CidrRoutes.subtract(Collections.singletonList("0.0.0.0/0"),
                Arrays.asList("203.0.113.10/32", "192.168.0.0/16"));
        assertFalse(captures(routes, "203.0.113.10/32"));
        assertFalse(captures(routes, "192.168.100.20/32"));
        assertTrue(captures(routes, "203.0.113.9/32"));
        assertTrue(captures(routes, "203.0.113.11/32"));
        assertTrue(captures(routes, "1.1.1.1/32"));
        for (CidrRoutes route : routes) {
            assertEquals(4, route.inetAddress().getAddress().length);
        }
        assertCanonical(routes);
    }

    @Test public void ipv6ExclusionsDoNotAffectIpv4() throws Exception {
        List<CidrRoutes> routes = CidrRoutes.subtract(Arrays.asList("0.0.0.0/0", "::/0"),
                Arrays.asList("2001:db8::/32", "::1/128"));
        assertFalse(captures(routes, "2001:db8::42/128"));
        assertFalse(captures(routes, "::1/128"));
        assertTrue(captures(routes, "2606:4700:4700::1111/128"));
        assertTrue(captures(routes, "0.0.0.1/32"));
        assertCanonical(routes);
    }

    @Test public void emptyIncludesAndCoveringExclusionsInstallNothing() throws Exception {
        assertTrue(CidrRoutes.subtract(Collections.emptyList(), Collections.singletonList("0.0.0.0/0")).isEmpty());
        assertTrue(CidrRoutes.subtract(Collections.singletonList("10.7.0.2/32"),
                Collections.singletonList("10.0.0.0/8")).isEmpty());
        assertTrue(CidrRoutes.subtract(Arrays.asList("0.0.0.0/0", "::/0"),
                Arrays.asList("::/0", "0.0.0.0/0")).isEmpty());
        assertRoutes(CidrRoutes.subtract(Arrays.asList("0.0.0.0/0", "::/0"),
                Collections.singletonList("::/0")), "0.0.0.0/0");
        assertRoutes(CidrRoutes.subtract(Arrays.asList("0.0.0.0/0", "::/0"),
                Collections.singletonList("0.0.0.0/0")), "::/0");
    }

    @Test public void normalizesPrefixesAndIgnoresDisjointExclusions() throws Exception {
        List<CidrRoutes> routes = CidrRoutes.subtract(Collections.singletonList("10.7.0.2/24"),
                Arrays.asList("192.0.2.0/24", "2001:db8::/32"));
        assertRoutes(routes, "10.7.0.0/24");
        assertTrue(captures(routes, "10.7.0.255/32"));
    }

    @Test public void coveringExclusionIsIndependentOfInputOrder() throws Exception {
        List<String> excluded = dispersedIpv6Hosts(100);
        excluded.add("2001:db8::/32");
        List<String> included = Collections.singletonList("::/0");
        List<CidrRoutes> coveringLast = CidrRoutes.subtract(included, excluded);
        Collections.reverse(excluded);
        List<CidrRoutes> coveringFirst = CidrRoutes.subtract(included, excluded);
        List<CidrRoutes> coveringOnly = CidrRoutes.subtract(included, Collections.singletonList("2001:db8::/32"));
        assertEquals(32, coveringLast.size());
        assertEquals(routeKeys(coveringOnly), routeKeys(coveringLast));
        assertEquals(routeKeys(coveringOnly), routeKeys(coveringFirst));
        assertFalse(captures(coveringLast, "2001:db8:ffff:ffff:ffff:ffff:ffff:ffff/128"));
        assertTrue(captures(coveringLast, "2001:db7:ffff:ffff:ffff:ffff:ffff:ffff/128"));
        assertTrue(captures(coveringLast, "2001:db9::/128"));
        assertCanonical(coveringLast);
    }

    @Test public void overlappingIncludesProduceUniqueFragments() throws Exception {
        List<String> included = Arrays.asList("10.0.0.1/24", "10.0.0.0/25", "10.0.0.128/25", "10.0.0.0/24",
                "2001:db8::/32", "2001:db8::1/64", "2001:0db8::/32");
        List<String> excluded = Arrays.asList("10.0.0.64/26", "2001:db8:4000::/34");
        List<CidrRoutes> routes = CidrRoutes.subtract(included, excluded);
        assertRoutes(routes, "10.0.0.0/26", "10.0.0.128/25", "2001:db8::/34", "2001:db8:8000::/33");
        List<String> reversed = new ArrayList<>(included);
        Collections.reverse(reversed);
        assertEquals(routeKeys(routes), routeKeys(CidrRoutes.subtract(reversed, excluded)));
    }

    @Test public void adjacentIncludesBecomeMinimalPrefixesWithoutExtraCoverage() throws Exception {
        List<CidrRoutes> routes = CidrRoutes.subtract(Arrays.asList(
                "10.0.0.128/26", "10.0.0.0/25", "10.0.0.192/26", "192.0.2.2/32", "192.0.2.0/31",
                "2001:db8:8000::/34", "2001:db8::/33", "2001:db8:c000::/34"), Collections.emptyList());
        assertRoutes(routes, "10.0.0.0/24", "192.0.2.0/31", "192.0.2.2/32", "2001:db8::/32");
        assertFalse(captures(routes, "192.0.2.3/32"));
        assertFalse(captures(routes, "10.0.1.0/32"));
    }

    @Test public void mergedExclusionCanSpanDisjointIncludes() throws Exception {
        List<CidrRoutes> routes = CidrRoutes.subtract(
                Arrays.asList("10.0.0.0/24", "10.0.2.0/24", "10.0.4.0/24"),
                Arrays.asList("10.0.2.0/25", "10.0.0.128/25", "10.0.1.0/24"));
        assertRoutes(routes, "10.0.0.0/25", "10.0.2.128/25", "10.0.4.0/24");
        assertTrue(CidrRoutes.subtract(Arrays.asList("10.0.0.0/24", "10.0.2.0/24", "10.1.0.0/24"),
                Collections.singletonList("10.0.0.0/15")).isEmpty());
    }

    @Test public void largeDisjointExclusionSetDoesNotChangeRemainingCoverage() throws Exception {
        List<String> included = Collections.singletonList("2001:db8::/32");
        List<String> inside = dispersedIpv6Hosts(65);
        List<CidrRoutes> expected = CidrRoutes.subtract(included, inside);
        List<String> excluded = new ArrayList<>(inside);
        for (int index = 0; index < 959; index++) {
            excluded.add("3000:" + Integer.toHexString(index) + "::1/128");
        }
        List<CidrRoutes> routes = CidrRoutes.subtract(included, excluded);
        assertEquals(routeKeys(expected), routeKeys(routes));
        for (String host : inside) assertFalse(captures(routes, host));
        assertTrue(captures(routes, "2001:db8::/128"));
        assertTrue(captures(routes, "2001:db8::2/128"));
        assertFalse(captures(routes, "3000::/128"));
        assertCanonical(routes);
    }

    @Test public void finalFragmentCountCanExceedTheRouteLimit() throws Exception {
        assertRouteLimit(Collections.singletonList("::/0"), dispersedIpv6Hosts(100));
    }

    @Test public void routeLimitAppliesAfterUnionAndSubtraction() throws Exception {
        List<String> included = new ArrayList<>();
        for (int index = 0; index <= CidrRoutes.MAX_ROUTES; index++) {
            included.add("10.0." + (index >> 7) + "." + ((index & 127) * 2) + "/32");
        }
        assertRouteLimit(included, Collections.emptyList());
        List<CidrRoutes> routes = CidrRoutes.subtract(included, Collections.singletonList(included.get(0)));
        assertEquals(CidrRoutes.MAX_ROUTES, routes.size());
        assertFalse(captures(routes, included.get(0)));
        assertTrue(captures(routes, included.get(included.size() - 1)));
        assertCanonical(routes);
        included.add("10.0.0.0/17");
        assertRoutes(CidrRoutes.subtract(included, Collections.emptyList()), "10.0.0.0/17");
    }

    @Test public void preservesEveryNonexcludedAddressInBothFamilies() throws Exception {
        List<CidrRoutes> routes = CidrRoutes.subtract(Arrays.asList("192.0.2.0/24", "2001:db8::/120"),
                Arrays.asList("192.0.2.0/32", "192.0.2.64/28", "192.0.2.255/32",
                        "2001:db8::/128", "2001:db8::40/124", "2001:db8::ff/128"));
        for (int value = 0; value < 256; value++) {
            boolean expected = value != 0 && value != 255 && (value < 64 || value >= 80);
            assertEquals("IPv4 address " + value, expected, captures(routes, "192.0.2." + value + "/32"));
            assertEquals("IPv6 address " + value, expected,
                    captures(routes, "2001:db8::" + Integer.toHexString(value) + "/128"));
        }
        assertFalse(captures(routes, "192.0.3.0/32"));
        assertFalse(captures(routes, "2001:db8::100/128"));
        assertCanonical(routes);
    }

    @Test public void defaultsRemainWholeAndKeepLoopbackCoverage() throws Exception {
        List<CidrRoutes> routes = CidrRoutes.subtract(Arrays.asList("0.0.0.0/0", "::/0"), Collections.emptyList());
        assertRoutes(routes, "0.0.0.0/0", "::/0");
        assertTrue(captures(routes, "127.0.0.1/32"));
        assertTrue(captures(routes, "::1/128"));
        assertRoutes(CidrRoutes.subtract(Arrays.asList("128.0.0.0/1", "0.0.0.0/1", "8000::/1", "::/1"),
                Collections.emptyList()), "0.0.0.0/0", "::/0");
    }

    @Test public void hostAndEdgePrefixesHandleAddressSpaceBoundaries() throws Exception {
        List<CidrRoutes> routes = CidrRoutes.subtract(Arrays.asList("255.255.255.254/31", "0.0.0.0/31",
                        "ffff:ffff:ffff:ffff:ffff:ffff:ffff:fffe/127", "::/127"),
                Arrays.asList("0.0.0.0/32", "255.255.255.255/32", "::/128",
                        "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff/128"));
        assertRoutes(routes, "0.0.0.1/32", "255.255.255.254/32", "::1/128",
                "ffff:ffff:ffff:ffff:ffff:ffff:ffff:fffe/128");
        assertEquals(128, CidrRoutes.parse("2001:db8::192.0.2.1/128").bits);
    }

    @Test public void ipv4MappedPrefixesKeepTheirIpv6Family() throws Exception {
        CidrRoutes mapped = CidrRoutes.parse("::ffff:192.0.2.1/128");
        assertEquals(128, mapped.bits);
        assertEquals(128, mapped.prefix);
        assertEquals(16, mapped.inetAddress().getAddress().length);
        assertEquals(CidrRoutes.parse("0:0:0:0:0:ffff:c000:201/128").address, mapped.address);
        assertRoutes(CidrRoutes.subtract(Collections.singletonList("192.0.2.0/24"),
                Collections.singletonList("::ffff:192.0.2.1/128")), "192.0.2.0/24");
        List<CidrRoutes> routes = CidrRoutes.subtract(Arrays.asList("192.0.2.0/24", "::ffff:192.0.2.0/127"),
                Collections.singletonList("::ffff:192.0.2.1/128"));
        assertRoutes(routes, "192.0.2.0/24", "::ffff:192.0.2.0/128");
        assertTrue(captures(routes, "192.0.2.1/32"));
        assertFalse(captures(routes, "::ffff:192.0.2.1/128"));
        assertTrue(captures(routes, "::ffff:192.0.2.0/128"));
    }

    @Test public void refusesHostnamesZonesAndInvalidPrefixes() throws Exception {
        for (String value : Arrays.asList("example.com/32", "face/32", "dead.beef/32", "1234/32", "127.1/32",
                "256.0.0.1/32", "1..2.3/32", "1.2.3.4.5/32", "127.0.0.1/33", "::/129", "10.0.0.1",
                "10.0.0.1/-1", "::/-1", "fe80::1%lo0/64", "fe80::1%1/64", "[::1]/128", "2001:db8:::1/64",
                "1:2:3:4:5:6:7/128", "1:2:3:4:5:6:7:8:9/128", "1:2:3:4:5:6:7:8::/128",
                "2001:db8::1::2/128", "::ffff:192.0.2.999/128", "192.0.2.1::/128", "10000::/64")) {
            try { CidrRoutes.parse(value); fail(value); }
            catch (CoreBridge.Failure error) { assertEquals("invalid_configuration", error.code); }
        }
    }
}
