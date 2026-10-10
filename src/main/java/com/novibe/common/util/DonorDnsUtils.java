package com.novibe.common.util;

import com.novibe.common.base_structures.BypassRoute;
import com.novibe.common.base_structures.DnsProfile;
import com.novibe.common.config.EnvironmentVariables;
import com.novibe.common.exception.UserInputException;
import org.xbill.DNS.ARecord;
import org.xbill.DNS.Address;
import org.xbill.DNS.DohResolver;
import org.xbill.DNS.Lookup;
import org.xbill.DNS.Record;
import org.xbill.DNS.Resolver;
import org.xbill.DNS.SimpleResolver;
import org.xbill.DNS.TextParseException;
import org.xbill.DNS.Type;

import java.net.UnknownHostException;
import java.time.Duration;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.SequencedSet;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;

import static java.util.Objects.isNull;

public class DonorDnsUtils {

    private static final int MAX_PARALLEL_QUERIES = 16;
    private static final int MAX_QUERY_ATTEMPTS = 2;

    public static void replaceIPs(List<BypassRoute> bypassRoutes, DnsProfile dnsProfile) {
        List<String> includedDomains = EnvParser.parse(EnvironmentVariables.DONOR_DNS_DOMAINS).stream()
                .map(DonorDnsUtils::normalizeDomain)
                .filter(domain -> !domain.isBlank())
                .toList();
        List<BypassRoute> routesToCheck = bypassRoutes.stream()
                .filter(route -> includedDomains.isEmpty() || matchesDomain(route.website(), includedDomains))
                .toList();

        if (routesToCheck.isEmpty()) {
            Log.fail("No redirect domains matched DONOR_DNS_DOMAINS");
            return;
        }

        Resolver dnsResolver = getDnsResolver(dnsProfile);
        dnsResolver.setTimeout(Duration.ofSeconds(5));

        Log.common("DNS donor will check %s of %s redirect domains"
                .formatted(routesToCheck.size(), bypassRoutes.size()));
        AtomicInteger changedRoutes = new AtomicInteger();
        AtomicInteger unresolvedRoutes = new AtomicInteger();
        int parallelQueries = Math.min(MAX_PARALLEL_QUERIES, routesToCheck.size());

        try (ExecutorService executor = Executors.newFixedThreadPool(parallelQueries)) {
            for (BypassRoute bypassRoute : routesToCheck) {
                Log.io("Comparing IP for %s with DNS query to %s".formatted(bypassRoute.website(), dnsProfile.donorDns()));
                executor.execute(() -> replaceIp(bypassRoute, dnsResolver, changedRoutes, unresolvedRoutes));
            }
        }

        Log.common("DNS donor check completed: %s checked, %s changed, %s unresolved"
                .formatted(routesToCheck.size(), changedRoutes.get(), unresolvedRoutes.get()));
    }

    private static void replaceIp(BypassRoute bypassRoute, Resolver dnsResolver,
                                  AtomicInteger changedRoutes, AtomicInteger unresolvedRoutes) {
        try {
            String currentIp = bypassRoute.ip();
            SequencedSet<String> donorIps = fetchDonorIps(bypassRoute.website(), dnsResolver);
            String newIp = chooseIp(currentIp, donorIps);

            if (donorIps.isEmpty()) {
                unresolvedRoutes.incrementAndGet();
                Log.fail("DNS donor returned no usable public IPv4 address for %s; retained source IP %s"
                        .formatted(bypassRoute.website(), currentIp));
            } else if (!currentIp.equals(newIp)) {
                Log.common("Changed IP for %s: %s -> %s".formatted(bypassRoute.website(), currentIp, newIp));
                bypassRoute.ip(newIp);
                changedRoutes.incrementAndGet();
            }
        } catch (RuntimeException e) {
            unresolvedRoutes.incrementAndGet();
            Log.fail("DNS donor check failed for %s; retained source IP %s: %s"
                    .formatted(bypassRoute.website(), bypassRoute.ip(), e.getMessage()));
        }
    }

    static boolean matchesDomain(String domain, List<String> includedDomains) {
        String normalizedDomain = normalizeDomain(domain);
        return includedDomains.stream()
                .anyMatch(included -> normalizedDomain.equals(included) || normalizedDomain.endsWith("." + included));
    }

    private static String normalizeDomain(String domain) {
        String normalized = domain.strip().toLowerCase(Locale.ROOT);
        return normalized.endsWith(".") ? normalized.substring(0, normalized.length() - 1) : normalized;
    }

    // Keep the source IP when it is still a usable answer; otherwise choose the first usable donor answer.
    static String chooseIp(String currentIp, SequencedSet<String> donorIps) {
        String firstUsableIp = null;
        for (String donorIp : donorIps) {
            if (!isUsableDonorIp(donorIp)) {
                continue;
            }
            if (donorIp.equals(currentIp)) {
                return currentIp;
            }
            if (isNull(firstUsableIp)) {
                firstUsableIp = donorIp;
            }
        }
        return isNull(firstUsableIp) ? currentIp : firstUsableIp;
    }

    private static Resolver getDnsResolver(DnsProfile dnsProfile) {
        String dns = dnsProfile.donorDns();
        try {
            if (dns.startsWith("http")) {
                return new DohResolver(dns);
            } else if (Address.isDottedQuad(dns)) {
                return new SimpleResolver(dns);
            } else {
                throw new UnknownHostException();
            }
        } catch (UnknownHostException e) {
            throw UserInputException.noStackTrace("Invalid DONOR_DNS value: %s. Value must follow Ipv4 or DoH format".formatted(dns));
        }
    }

    private static SequencedSet<String> fetchDonorIps(String domain, Resolver resolver) {
        for (int attempt = 0; attempt < MAX_QUERY_ATTEMPTS; attempt++) {
            try {
                Lookup lookup = new Lookup(domain, Type.A);
                lookup.setResolver(resolver);
                Record[] records = lookup.run();
                if (isNull(records)) {
                    continue;
                }

                SequencedSet<String> donorIps = new LinkedHashSet<>();
                for (Record record : records) {
                    if (record instanceof ARecord aRecord) {
                        String donorIp = aRecord.getAddress().getHostAddress();
                        if (isUsableDonorIp(donorIp)) {
                            donorIps.add(donorIp);
                        }
                    }
                }
                if (!donorIps.isEmpty()) {
                    return donorIps;
                }
            } catch (TextParseException e) {
                Log.fail("Invalid domain address: " + domain);
                return new LinkedHashSet<>();
            } catch (RuntimeException e) {
                Log.fail("DNS donor query failed for %s (attempt %s/%s): %s"
                        .formatted(domain, attempt + 1, MAX_QUERY_ATTEMPTS, e.getMessage()));
            }
        }
        return new LinkedHashSet<>();
    }

    private static boolean isUsableDonorIp(String address) {
        int[] octets = parseIpv4(address);
        if (isNull(octets)) {
            return false;
        }

        int first = octets[0];
        int second = octets[1];
        int third = octets[2];
        int fourth = octets[3];

        // Reject non-public address blocks that cannot be valid public-service answers.
        return !(first == 0 || first == 10 || first == 127 || first >= 224
                || first == 100 && second >= 64 && second <= 127
                || first == 169 && second == 254
                || first == 172 && second >= 16 && second <= 31
                || first == 192 && second == 168
                || first == 192 && second == 0 && third == 0 && fourth != 9 && fourth != 10
                || first == 192 && second == 0 && third == 2
                || first == 192 && second == 88 && third == 99
                || first == 198 && second >= 18 && second <= 19
                || first == 198 && second == 51 && third == 100
                || first == 203 && second == 0 && third == 113);
    }

    private static int[] parseIpv4(String address) {
        if (isNull(address)) {
            return null;
        }

        String[] parts = address.split("\\.", -1);
        if (parts.length != 4) {
            return null;
        }

        int[] octets = new int[4];
        for (int i = 0; i < parts.length; i++) {
            String part = parts[i];
            if (part.isEmpty() || part.length() > 1 && part.charAt(0) == '0') {
                return null;
            }

            int octet = 0;
            for (int j = 0; j < part.length(); j++) {
                char digit = part.charAt(j);
                if (digit < '0' || digit > '9') {
                    return null;
                }
                octet = octet * 10 + digit - '0';
                if (octet > 255) {
                    return null;
                }
            }
            octets[i] = octet;
        }
        return octets;
    }
}
