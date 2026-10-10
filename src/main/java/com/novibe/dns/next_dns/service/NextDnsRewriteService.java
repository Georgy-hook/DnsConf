package com.novibe.dns.next_dns.service;

import com.novibe.common.base_structures.BypassRoute;
import com.novibe.common.exception.UserInputException;
import com.novibe.common.service.ExcludeRedirectCheckService;
import com.novibe.common.util.Log;
import com.novibe.dns.next_dns.http.NextDnsRateLimitedApiProcessor;
import com.novibe.dns.next_dns.http.NextDnsRewriteClient;
import com.novibe.dns.next_dns.http.dto.request.CreateRewriteDto;
import com.novibe.dns.next_dns.http.dto.response.rewrite.RewriteDto;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

import static java.util.Objects.nonNull;

@Service
@RequiredArgsConstructor
public class NextDnsRewriteService {

    private final NextDnsRewriteClient nextDnsRewriteClient;
    private final ExcludeRedirectCheckService excludeRedirectCheckService;

    public Map<String, CreateRewriteDto> buildNewRewrites(List<BypassRoute> overrides) {
        Map<String, CreateRewriteDto> rewriteDtos = new HashMap<>();
        overrides.forEach(route -> rewriteDtos.putIfAbsent(route.website(), new CreateRewriteDto(route.website(), route.ip())));
        return rewriteDtos;
    }

    public List<CreateRewriteDto> cleanupOutdatedAndExcluded(Map<String, CreateRewriteDto> newRewriteRequests) {
        return cleanupOutdatedAndExcluded(newRewriteRequests, List.of());
    }

    public List<CreateRewriteDto> cleanupOutdatedAndExcluded(
            Map<String, CreateRewriteDto> newRewriteRequests,
            List<String> synchronizedDomains
    ) {
        List<String> normalizedSynchronizedDomains = normalizeSynchronizedDomains(synchronizedDomains);
        requireSynchronizedRoots(newRewriteRequests, normalizedSynchronizedDomains);

        List<RewriteDto> existingRewrites = getExistingRewrites();

        List<String> outdatedIds = new ArrayList<>();
        List<String> ignoredIds = new ArrayList<>();
        List<String> obsoleteIds = new ArrayList<>();
        List<String> obsoleteDomains = new ArrayList<>();
        Map<String, String> requestKeysByNormalizedDomain = indexRequestKeysByNormalizedDomain(newRewriteRequests);

        for (RewriteDto existingRewrite : existingRewrites) {
            String domain = existingRewrite.name();
            String oldIp = existingRewrite.content();
            boolean synchronizedDomain = isSynchronizedDomain(domain, normalizedSynchronizedDomains);
            String requestKey = synchronizedDomain
                    ? requestKeysByNormalizedDomain.get(normalizeDomain(domain))
                    : domain;

            if (excludeRedirectCheckService.shouldExclude(domain)) {
                ignoredIds.add(existingRewrite.id());
                if (nonNull(requestKey)) {
                    newRewriteRequests.remove(requestKey);
                }
                continue;
            }

            if (synchronizedDomain && !nonNull(requestKey)) {
                obsoleteIds.add(existingRewrite.id());
                obsoleteDomains.add(domain);
                continue;
            }

            CreateRewriteDto request = nonNull(requestKey) ? newRewriteRequests.get(requestKey) : null;
            if (nonNull(request) && !request.content().equals(oldIp)) {
                outdatedIds.add(existingRewrite.id());
            } else {
                if (nonNull(requestKey)) {
                    newRewriteRequests.remove(requestKey);
                }
            }
        }
        newRewriteRequests.keySet().removeIf(excludeRedirectCheckService::shouldExclude);

        if (!outdatedIds.isEmpty()) {
            Log.io("Removing %s outdated rewrites from NextDNS".formatted(outdatedIds.size()));
            NextDnsRateLimitedApiProcessor.callApi(outdatedIds, nextDnsRewriteClient::deleteRewriteById);
        }
        if (!obsoleteIds.isEmpty()) {
            Log.io("Removing %s obsolete synchronized rewrites from NextDNS for domains: %s"
                    .formatted(obsoleteIds.size(), obsoleteDomains));
            NextDnsRateLimitedApiProcessor.callApi(obsoleteIds, nextDnsRewriteClient::deleteRewriteById);
        }
        if (!ignoredIds.isEmpty()) {
            Log.io("Removing %s excluded rewrites from NextDNS".formatted(ignoredIds.size()));
            NextDnsRateLimitedApiProcessor.callApi(ignoredIds, nextDnsRewriteClient::deleteRewriteById);
        }
        return List.copyOf(newRewriteRequests.values());
    }

    public void verifySynchronizedRewrites(
            Map<String, CreateRewriteDto> desiredRequests,
            List<String> synchronizedDomains
    ) {
        List<String> normalizedSynchronizedDomains = normalizeSynchronizedDomains(synchronizedDomains);
        if (normalizedSynchronizedDomains.isEmpty()) {
            return;
        }
        requireSynchronizedRoots(desiredRequests, normalizedSynchronizedDomains);

        Map<String, CreateRewriteDto> desiredScopedRequests = new HashMap<>();
        desiredRequests.forEach((name, request) -> {
            String normalizedName = normalizeDomain(name);
            if (isSynchronizedDomain(normalizedName, normalizedSynchronizedDomains)
                    && !excludeRedirectCheckService.shouldExclude(normalizedName)) {
                desiredScopedRequests.putIfAbsent(normalizedName, request);
            }
        });

        List<String> missingDomains = new ArrayList<>();
        List<String> mismatchedDomains = new ArrayList<>();
        List<String> unexpectedDomains = new ArrayList<>();
        Set<String> foundDomains = new HashSet<>();

        for (RewriteDto existingRewrite : getExistingRewrites()) {
            String normalizedName = normalizeDomain(existingRewrite.name());
            if (!isSynchronizedDomain(normalizedName, normalizedSynchronizedDomains)) {
                continue;
            }
            if (excludeRedirectCheckService.shouldExclude(normalizedName)) {
                unexpectedDomains.add(existingRewrite.name());
                continue;
            }

            CreateRewriteDto desiredRequest = desiredScopedRequests.get(normalizedName);
            if (desiredRequest == null) {
                unexpectedDomains.add(existingRewrite.name());
                continue;
            }
            foundDomains.add(normalizedName);
            if (!desiredRequest.content().equals(existingRewrite.content())) {
                mismatchedDomains.add(existingRewrite.name());
            }
        }

        desiredScopedRequests.forEach((name, request) -> {
            if (!foundDomains.contains(name)) {
                missingDomains.add(request.name());
            }
        });

        if (!missingDomains.isEmpty() || !mismatchedDomains.isEmpty() || !unexpectedDomains.isEmpty()) {
            List<String> problems = new ArrayList<>();
            if (!missingDomains.isEmpty()) {
                problems.add("missing requested rewrites: " + missingDomains);
            }
            if (!mismatchedDomains.isEmpty()) {
                problems.add("content mismatch: " + mismatchedDomains);
            }
            if (!unexpectedDomains.isEmpty()) {
                problems.add("unexpected or excluded rewrites: " + unexpectedDomains);
            }
            throw UserInputException.noStackTrace(
                    "SYNC_REDIRECT_DOMAINS verification failed: " + String.join("; ", problems)
            );
        }

        Log.io("Verified %s synchronized rewrites across %s domains"
                .formatted(desiredScopedRequests.size(), normalizedSynchronizedDomains.size()));
        for (String root : normalizedSynchronizedDomains) {
            CreateRewriteDto verifiedRoot = desiredScopedRequests.get(root);
            if (verifiedRoot != null) {
                Log.io("Verified NextDNS rewrite: %s -> %s".formatted(root, verifiedRoot.content()));
            }
        }
    }

    private static List<String> normalizeSynchronizedDomains(List<String> synchronizedDomains) {
        return synchronizedDomains.stream()
                .map(NextDnsRewriteService::normalizeDomain)
                .filter(domain -> !domain.isEmpty())
                .distinct()
                .toList();
    }

    private static void requireSynchronizedRoots(
            Map<String, CreateRewriteDto> newRewriteRequests,
            List<String> synchronizedDomains
    ) {
        Set<String> requestedDomains = new HashSet<>();
        newRewriteRequests.keySet().forEach(domain -> requestedDomains.add(normalizeDomain(domain)));

        List<String> missingRoots = synchronizedDomains.stream()
                .filter(domain -> !requestedDomains.contains(domain))
                .toList();
        if (!missingRoots.isEmpty()) {
            throw UserInputException.noStackTrace(
                    "SYNC_REDIRECT_DOMAINS requires each root domain in the redirect sources. Missing: "
                            + String.join(", ", missingRoots)
            );
        }
    }

    private static Map<String, String> indexRequestKeysByNormalizedDomain(
            Map<String, CreateRewriteDto> newRewriteRequests
    ) {
        Map<String, String> requestKeys = new HashMap<>();
        newRewriteRequests.keySet().forEach(key -> requestKeys.putIfAbsent(normalizeDomain(key), key));
        return requestKeys;
    }

    private static boolean isSynchronizedDomain(String domain, List<String> synchronizedDomains) {
        String normalizedDomain = normalizeDomain(domain);
        return synchronizedDomains.stream()
                .anyMatch(root -> normalizedDomain.equals(root) || normalizedDomain.endsWith("." + root));
    }

    private static String normalizeDomain(String domain) {
        String normalizedDomain = domain.strip().toLowerCase(Locale.ROOT);
        if (normalizedDomain.endsWith(".")) {
            return normalizedDomain.substring(0, normalizedDomain.length() - 1);
        }
        return normalizedDomain;
    }

    public List<RewriteDto> getExistingRewrites() {
        Log.io("Fetching existing rewrites from NextDNS");
        return nextDnsRewriteClient.fetchRewrites();
    }

    public void saveRewrites(List<CreateRewriteDto> createRewriteDtos) {
        Log.io("Saving %s new rewrites to NextDNS...".formatted(createRewriteDtos.size()));
        NextDnsRateLimitedApiProcessor.callApi(createRewriteDtos, nextDnsRewriteClient::saveRewrite);
    }

    public void removeAll() {
        Log.io("Fetching existing rewrites from NextDNS");
        List<RewriteDto> list = nextDnsRewriteClient.fetchRewrites();
        List<String> ids = list.stream().map(RewriteDto::id).toList();
        Log.io("Removing rewrites from NextDNS");
        NextDnsRateLimitedApiProcessor.callApi(ids, nextDnsRewriteClient::deleteRewriteById);
    }

}
