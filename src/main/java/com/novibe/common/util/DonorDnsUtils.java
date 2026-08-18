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
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;

import static java.util.Objects.isNull;
import static java.util.Objects.nonNull;

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
                executor.submit(() -> replaceIp(bypassRoute, dnsResolver, changedRoutes, unresolvedRoutes));
            }
        }

        Log.common("DNS donor check completed: %s checked, %s changed, %s unresolved"
                .formatted(routesToCheck.size(), changedRoutes.get(), unresolvedRoutes.get()));
    }

    private static void replaceIp(BypassRoute bypassRoute, Resolver dnsResolver,
                                  AtomicInteger changedRoutes, AtomicInteger unresolvedRoutes) {
        String donorIp = fetchDonorIp(bypassRoute.website(), dnsResolver);
        if (isNull(donorIp)) {
            unresolvedRoutes.incrementAndGet();
            Log.fail("DNS donor returned no IPv4 address for " + bypassRoute.website());
        } else if (!bypassRoute.ip().equals(donorIp)) {
            Log.common("Changed IP for %s: %s -> %s".formatted(bypassRoute.website(), bypassRoute.ip(), donorIp));
            bypassRoute.ip(donorIp);
            changedRoutes.incrementAndGet();
        }
    }

    private static boolean matchesDomain(String domain, List<String> includedDomains) {
        String normalizedDomain = normalizeDomain(domain);
        return includedDomains.stream()
                .anyMatch(included -> normalizedDomain.equals(included) || normalizedDomain.endsWith("." + included));
    }

    private static String normalizeDomain(String domain) {
        String normalized = domain.strip().toLowerCase(Locale.ROOT);
        return normalized.endsWith(".") ? normalized.substring(0, normalized.length() - 1) : normalized;
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

    private static String fetchDonorIp(String domain, Resolver resolver) {
        try {
            for (int attempt = 0; attempt < MAX_QUERY_ATTEMPTS; attempt++) {
                Lookup lookup = new Lookup(domain, Type.A);
                lookup.setResolver(resolver);
                Record[] records = lookup.run();
                if (nonNull(records) && records.length > 0) {
                    return ((ARecord) records[0]).getAddress().getHostAddress();
                }
            }
            return null;
        } catch (TextParseException e) {
            Log.fail("Invalid domain address: " + domain);
            return null;
        }
    }

}
