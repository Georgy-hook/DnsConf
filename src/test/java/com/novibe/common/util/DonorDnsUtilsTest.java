package com.novibe.common.util;

import org.junit.jupiter.api.Test;

import java.util.LinkedHashSet;
import java.util.List;
import java.util.SequencedSet;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class DonorDnsUtilsTest {

    private static SequencedSet<String> donorIps(String... ips) {
        return new LinkedHashSet<>(List.of(ips));
    }

    @Test
    void keepsCurrentIpWhenDonorStillReturnsIt() {
        assertEquals("1.1.1.2", DonorDnsUtils.chooseIp("1.1.1.2", donorIps("1.1.1.1", "1.1.1.2", "1.1.1.3")));
    }

    @Test
    void takesFirstDonorIpWhenCurrentIpIsOutdated() {
        assertEquals("1.1.1.1", DonorDnsUtils.chooseIp("9.9.9.9", donorIps("1.1.1.1", "1.1.1.2")));
    }

    @Test
    void keepsCurrentIpWhenDonorReturnsNothing() {
        assertEquals("9.9.9.9", DonorDnsUtils.chooseIp("9.9.9.9", donorIps()));
    }

    @Test
    void keepsCurrentIpWhenDonorOnlyReturnsSinkholeAddress() {
        assertEquals("193.233.112.88", DonorDnsUtils.chooseIp("193.233.112.88", donorIps("0.0.0.0")));
    }

    @Test
    void skipsNonPublicAnswersAndChoosesFirstPublicAnswerInResponseOrder() {
        assertEquals("8.8.8.8", DonorDnsUtils.chooseIp("9.9.9.9", donorIps(
                "0.0.0.0", "10.1.2.3", "127.0.0.1", "169.254.1.1", "172.16.0.1",
                "192.168.1.2", "224.0.0.1", "255.255.255.255", "198.51.100.7", "8.8.8.8", "1.1.1.1")));
    }

    @Test
    void keepsCurrentIpWhenItIsAmongUsableAnswersAfterBlockedAnswers() {
        assertEquals("1.1.1.1", DonorDnsUtils.chooseIp("1.1.1.1", donorIps("0.0.0.0", "8.8.8.8", "1.1.1.1")));
    }

    @Test
    void rejectsMalformedIpv4AndIpv6Answers() {
        String currentIp = "9.9.9.9";
        assertEquals(currentIp, DonorDnsUtils.chooseIp(currentIp, donorIps(
                "999.1.1.1", "1.2.3", "01.2.3.4", "2001:4860:4860::8888", "::ffff:8.8.8.8")));
    }

    @Test
    void keepsCurrentIpWhenDonorOnlyReturnsPrivateAndLoopbackAddresses() {
        String currentIp = "9.9.9.9";
        assertEquals(currentIp, DonorDnsUtils.chooseIp(currentIp, donorIps(
                "10.0.0.1", "172.31.255.255", "192.168.0.1", "127.0.0.1")));
    }

    @Test
    void matchesIncludedDomainOnlyAtDomainSuffixBoundary() {
        List<String> includedDomains = List.of("openai.com");

        assertTrue(DonorDnsUtils.matchesDomain("openai.com", includedDomains));
        assertTrue(DonorDnsUtils.matchesDomain("api.openai.com.", includedDomains));
        assertFalse(DonorDnsUtils.matchesDomain("notopenai.com", includedDomains));
        assertFalse(DonorDnsUtils.matchesDomain("openai.com.attacker.example", includedDomains));
    }
}
