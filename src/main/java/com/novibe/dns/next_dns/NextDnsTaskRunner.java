package com.novibe.dns.next_dns;

import com.novibe.common.DnsTaskRunner;
import com.novibe.common.base_structures.BypassRoute;
import com.novibe.common.exception.UserInputException;
import com.novibe.common.util.DonorDnsUtils;
import com.novibe.common.util.EnvParser;
import com.novibe.common.util.Log;
import com.novibe.dns.next_dns.http.dto.request.CreateRewriteDto;
import com.novibe.dns.next_dns.service.NextDnsDenyService;
import com.novibe.dns.next_dns.service.NextDnsRewriteService;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;

import java.util.List;
import java.util.Locale;
import java.util.Map;

import static com.novibe.common.config.EnvironmentVariables.BLOCK;
import static com.novibe.common.config.EnvironmentVariables.REDIRECT;
import static com.novibe.common.config.EnvironmentVariables.SYNC_REDIRECT_DOMAINS;
import static java.util.Objects.nonNull;

@Service
@RequiredArgsConstructor
public class NextDnsTaskRunner extends DnsTaskRunner {

    private final NextDnsRewriteService nextDnsRewriteService;
    private final NextDnsDenyService nextDnsDenyService;

    @Override
    public void greetingMessage() {
        Log.global("Setting up Profile " + dnsProfile.number() + " (NextDNS)");
        Log.common("""
                Script behaviour: old BLOCK/REDIRECT settings are about to be updated via provided BLOCK/REDIRECT sources.
                - if no sources provided, then all NextDNS settings will be removed.
                - each line is mapped to an IP–domain pair; lines that cannot be parsed are skipped.
                - if provided only one type of sources, related settings will be updated; another type remain untouched.
                - if EXCLUDE_REDIRECT domains provided, they will affect both existing and new redirect rules.
                - optional SYNC_REDIRECT_DOMAINS removes obsolete rules for listed roots and their subdomains; each root must be present in the redirect sources.
                NextDNS api rate limiter reset config: 60 seconds after the last request""");
    }

    @Override
    protected void process() {
        process(
                EnvParser.parse(BLOCK),
                EnvParser.parse(REDIRECT),
                parseSynchronizedRedirectDomains()
        );
    }

    void process(
            List<String> blockSources,
            List<String> rewriteSources,
            List<String> synchronizedDomains
    ) {
        if (!synchronizedDomains.isEmpty() && rewriteSources.isEmpty()) {
            throw UserInputException.noStackTrace(
                    "SYNC_REDIRECT_DOMAINS requires at least one REDIRECT source; refusing to remove settings"
            );
        }

        if (!blockSources.isEmpty()) {
            Log.step("Obtain block lists from %s sources".formatted(blockSources.size()));
            List<String> blocks = blockListsLoader.fetchWebsites(blockSources);
            Log.step("Prepare denylist");
            List<String> filteredBlocklist = nextDnsDenyService.omitExistingDenys(blocks);
            Log.common("Prepared %s domains to block".formatted(filteredBlocklist.size()));
            Log.step("Save denylist");
            nextDnsDenyService.saveDenyList(filteredBlocklist);
        } else {
            Log.fail("No block sources provided");
        }

        if (!rewriteSources.isEmpty()) {

            Log.step("Obtain rewrite lists from %s sources".formatted(rewriteSources.size()));
            List<BypassRoute> overrides = overrideListsLoader.fetchWebsites(rewriteSources);

            if (nonNull(dnsProfile.donorDns())) {
                Log.step("Replace IP of domains via IPs from " + dnsProfile.donorDns());
                DonorDnsUtils.replaceIPs(overrides, dnsProfile);
            }

            Log.step("Prepare rewrites");
            Map<String, CreateRewriteDto> requests = nextDnsRewriteService.buildNewRewrites(overrides);
            Map<String, CreateRewriteDto> desiredRequests = Map.copyOf(requests);
            List<CreateRewriteDto> createRewriteDtos = nextDnsRewriteService.cleanupOutdatedAndExcluded(
                    requests,
                    synchronizedDomains
            );

            Log.step("Save rewrites");
            nextDnsRewriteService.saveRewrites(createRewriteDtos);
            if (!synchronizedDomains.isEmpty()) {
                nextDnsRewriteService.verifySynchronizedRewrites(desiredRequests, synchronizedDomains);
            }
        } else {
            Log.fail("No rewrite sources provided");
        }

        if (blockSources.isEmpty() && rewriteSources.isEmpty()) {
            Log.step("Remove settings");
            nextDnsDenyService.removeAll();
            nextDnsRewriteService.removeAll();
        }
    }

    private static List<String> parseSynchronizedRedirectDomains() {
        return EnvParser.parse(SYNC_REDIRECT_DOMAINS).stream()
                .map(domain -> domain.toLowerCase(Locale.ROOT))
                .map(domain -> domain.endsWith(".") ? domain.substring(0, domain.length() - 1) : domain)
                .filter(domain -> !domain.isEmpty())
                .distinct()
                .toList();
    }

    @Override
    protected void finishMessage() {
        Log.global("Profile " + dnsProfile.number() + " (NextDNS) set up successfully");
    }
}
