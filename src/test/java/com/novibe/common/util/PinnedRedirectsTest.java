package com.novibe.common.util;

import com.novibe.common.base_structures.BypassRoute;
import com.novibe.common.exception.UserInputException;
import org.junit.jupiter.api.Test;
import java.util.List;
import static org.junit.jupiter.api.Assertions.*;

class PinnedRedirectsTest {
    @Test void replacesDonorAndSpecificRulesWithoutTouchingOtherServices() {
        var original = List.of(new BypassRoute("193.233.112.88", "oaiusercontent.com"),
                new BypassRoute("193.233.112.67", "sdmntprwestus.oaiusercontent.com"),
                new BypassRoute("1.2.3.4", "notoaiusercontent.com"),
                new BypassRoute("5.6.7.8", "cdn.other.example"));
        var actual = PinnedRedirects.apply(original, PinnedRedirects.parse("oaiusercontent.com=45.13.237.213"));
        assertEquals(List.of(original.get(2), original.get(3), new BypassRoute("45.13.237.213", "oaiusercontent.com")), actual);
        assertEquals(4, original.size());
    }
    @Test void normalizesCaseAndTrailingDot() {
        var actual = PinnedRedirects.apply(List.of(new BypassRoute("1.2.3.4", "CDN.CHATGPT.COM.")),
                PinnedRedirects.parse(" CHATGPT.COM. = 192.255.159.241 "));
        assertEquals(List.of(new BypassRoute("192.255.159.241", "chatgpt.com")), actual);
    }
    @Test void missingPinsRetainLegacyRoutes() {
        var original = List.of(new BypassRoute("1.2.3.4", "example.com"));
        assertEquals(original, PinnedRedirects.apply(original, PinnedRedirects.parse(null)));
    }
    @Test void refusesAmbiguousOrMalformedConfiguration() {
        for (String input : List.of("example.com=999.1.1.1", "*.example.com=1.2.3.4",
                "example.com=1.2.3.4,sub.example.com=5.6.7.8", "example.com=1.2.3.4,EXAMPLE.COM=5.6.7.8",
                "example.com=1.2.3.4,", "bad=1.2.3.4", "example.com=01.2.3.4")) {
            assertThrows(UserInputException.class, () -> PinnedRedirects.parse(input), input);
        }
    }
}
