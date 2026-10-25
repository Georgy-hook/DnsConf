package com.novibe.common.util;

import com.novibe.common.base_structures.BypassRoute;
import com.novibe.common.exception.UserInputException;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/** Explicit administrator routes take precedence over downloaded lists and donors. */
public final class PinnedRedirects {
    private PinnedRedirects() {}

    public static List<BypassRoute> parse(String value) {
        List<BypassRoute> pins = new ArrayList<>();
        if (value == null || value.isBlank()) return pins;
        for (String entry : value.split(",", -1)) {
            String[] pair = entry.trim().split("=", -1);
            if (pair.length != 2) throw invalid();
            String domain = pair[0].trim().toLowerCase(Locale.ROOT);
            String ip = pair[1].trim();
            if (domain.endsWith(".")) domain = domain.substring(0, domain.length() - 1);
            if (domain.length() > 253 || !domain.matches("[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+")
                    || !ip.matches("(?:[0-9]{1,3}\\.){3}[0-9]{1,3}")) throw invalid();
            String[] octets = ip.split("\\.");
            for (String octet : octets) {
                if (Integer.parseInt(octet) > 255 || (octet.length() > 1 && octet.startsWith("0"))) throw invalid();
            }
            if (Integer.parseInt(octets[0]) == 0 || Integer.parseInt(octets[0]) >= 224) throw invalid();
            for (BypassRoute pin : pins) {
                if (matches(domain, pin.website()) || matches(pin.website(), domain)) throw invalid();
            }
            pins.add(new BypassRoute(ip, domain));
        }
        return pins;
    }

    public static List<BypassRoute> apply(List<BypassRoute> routes, List<BypassRoute> pins) {
        List<BypassRoute> result = new ArrayList<>();
        for (BypassRoute route : routes) {
            if (pins.stream().noneMatch(pin -> matches(route.website(), pin.website()))) result.add(route);
        }
        result.addAll(pins);
        return result;
    }

    private static boolean matches(String domain, String root) {
        String normalized = domain.toLowerCase(Locale.ROOT);
        if (normalized.endsWith(".")) normalized = normalized.substring(0, normalized.length() - 1);
        return normalized.equals(root) || normalized.endsWith("." + root);
    }

    private static UserInputException invalid() {
        return UserInputException.noStackTrace("PINNED_REDIRECTS requires non-overlapping domain=IPv4 entries separated by commas");
    }
}
