package dev.idy.wgcne;

import org.junit.Test;
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
    }

    @Test public void ipv6ExclusionsDoNotAffectIpv4() throws Exception {
        List<CidrRoutes> routes = CidrRoutes.subtract(Arrays.asList("0.0.0.0/0", "::/0"),
                Arrays.asList("2001:db8::/32", "::1/128"));
        assertFalse(captures(routes, "2001:db8::42/128"));
        assertFalse(captures(routes, "::1/128"));
        assertTrue(captures(routes, "2606:4700:4700::1111/128"));
        assertTrue(captures(routes, "0.0.0.1/32"));
        for (CidrRoutes route : routes) assertNotNull(route.inetAddress());
    }

    @Test public void emptyIncludesAndCoveringExclusionsInstallNothing() throws Exception {
        assertTrue(CidrRoutes.subtract(Collections.emptyList(), Collections.singletonList("0.0.0.0/0")).isEmpty());
        assertTrue(CidrRoutes.subtract(Collections.singletonList("10.7.0.2/32"),
                Collections.singletonList("10.0.0.0/8")).isEmpty());
    }

    @Test public void normalizesPrefixesAndIgnoresDisjointExclusions() throws Exception {
        List<CidrRoutes> routes = CidrRoutes.subtract(Collections.singletonList("10.7.0.2/24"),
                Arrays.asList("192.0.2.0/24", "2001:db8::/32"));
        assertEquals(1, routes.size());
        assertEquals("10.7.0.0", routes.get(0).inetAddress().getHostAddress());
        assertTrue(captures(routes, "10.7.0.255/32"));
    }

    @Test public void refusesHostnamesAndInvalidPrefixes() throws Exception {
        for (String value : Arrays.asList("example.com/32", "127.0.0.1/33", "::/129", "10.0.0.1", "fe80::1%lo0/64")) {
            try { CidrRoutes.parse(value); fail(value); }
            catch (CoreBridge.Failure error) { assertEquals("invalid_configuration", error.code); }
        }
    }
}
