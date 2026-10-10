package com.novibe.dns.next_dns.service;

import com.novibe.common.data_sources.ExcludeRedirectSettingsLoader;
import com.novibe.common.exception.UserInputException;
import com.novibe.common.service.ExcludeRedirectCheckService;
import com.novibe.dns.next_dns.http.NextDnsRewriteClient;
import com.novibe.dns.next_dns.http.dto.request.CreateRewriteDto;
import com.novibe.dns.next_dns.http.dto.response.rewrite.RewriteDto;
import com.novibe.dns.next_dns.http.dto.response.rewrite.SingleRewriteResponse;
import org.junit.jupiter.api.Test;
import org.jspecify.annotations.Nullable;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class NextDnsRewriteServiceTest {

    @Test
    void removesObsoleteSubdomainsWithinTheSynchronizedRootAndKeepsUnrelatedRules() {
        StubRewriteClient client = client(
                rewrite("root", "chatgpt.com", "193.233.112.1"),
                rewrite("obsolete", "ws.chatgpt.com", "87.228.47.204"),
                rewrite("manual", "manual.example.com", "192.0.2.10")
        );
        NextDnsRewriteService service = service(client);
        Map<String, CreateRewriteDto> requests = requests(
                request("chatgpt.com", "193.233.112.1")
        );

        List<CreateRewriteDto> toCreate = service.cleanupOutdatedAndExcluded(requests, List.of("chatgpt.com"));

        assertEquals(List.of("obsolete"), client.deletedIds);
        assertEquals(List.of(), toCreate);
    }

    @Test
    void emptyScopePreservesLegacyBehavior() {
        StubRewriteClient client = client(
                rewrite("obsolete", "ws.chatgpt.com", "87.228.47.204")
        );
        NextDnsRewriteService service = service(client);
        CreateRewriteDto root = request("chatgpt.com", "193.233.112.1");

        List<CreateRewriteDto> toCreate = service.cleanupOutdatedAndExcluded(requests(root));

        assertEquals(List.of(), client.deletedIds);
        assertEquals(List.of(root), toCreate);
    }

    @Test
    void onlyMatchesAnExactRootOrItsSubdomains() {
        StubRewriteClient client = client(
                rewrite("valid-child", "api.chatgpt.com", "87.228.47.204"),
                rewrite("prefix-lookalike", "notchatgpt.com", "192.0.2.11"),
                rewrite("suffix-lookalike", "chatgpt.com.attacker.test", "192.0.2.12")
        );
        NextDnsRewriteService service = service(client);

        List<CreateRewriteDto> toCreate = service.cleanupOutdatedAndExcluded(
                requests(request("chatgpt.com", "193.233.112.1")),
                List.of(" ChatGPT.COM. ")
        );

        assertEquals(List.of("valid-child"), client.deletedIds);
        assertEquals(List.of(request("chatgpt.com", "193.233.112.1")), toCreate);
    }

    @Test
    void keepsUnchangedRequestedRulesAndRecreatesChangedRequestedRules() {
        StubRewriteClient client = client(
                rewrite("root", "chatgpt.com", "193.233.112.1"),
                rewrite("api", "api.chatgpt.com", "87.228.47.204")
        );
        NextDnsRewriteService service = service(client);
        CreateRewriteDto changedSubdomain = request("api.chatgpt.com", "193.233.112.2");
        Map<String, CreateRewriteDto> requests = requests(
                request("chatgpt.com", "193.233.112.1"),
                changedSubdomain
        );

        List<CreateRewriteDto> toCreate = service.cleanupOutdatedAndExcluded(requests, List.of("chatgpt.com"));

        assertEquals(List.of("api"), client.deletedIds);
        assertEquals(List.of(changedSubdomain), toCreate);
    }

    @Test
    void failsBeforeFetchingRewritesWhenAnySynchronizedRootIsMissing() {
        StubRewriteClient client = client();
        NextDnsRewriteService service = service(client);

        assertThrows(
                UserInputException.class,
                () -> service.cleanupOutdatedAndExcluded(Map.of(), List.of("chatgpt.com", "openai.com"))
        );

        assertEquals(0, client.fetchCount);
        assertEquals(List.of(), client.deletedIds);
        assertEquals(List.of(), client.savedRequests);
    }

    @Test
    void verifiesTheScopedStateAfterSaving() {
        RewriteDto root = rewrite("root", "chatgpt.com", "193.233.112.1");
        RewriteDto api = rewrite("api", "api.chatgpt.com", "193.233.112.2");
        StubRewriteClient client = client(List.of(root, api), List.of(root, api));
        NextDnsRewriteService service = service(client);
        Map<String, CreateRewriteDto> desiredRequests = Map.copyOf(requests(
                request("chatgpt.com", "193.233.112.1"),
                request("api.chatgpt.com", "193.233.112.2")
        ));
        Map<String, CreateRewriteDto> mutableRequests = new LinkedHashMap<>(desiredRequests);

        List<CreateRewriteDto> toCreate = service.cleanupOutdatedAndExcluded(mutableRequests, List.of("chatgpt.com"));
        service.saveRewrites(toCreate);
        service.verifySynchronizedRewrites(desiredRequests, List.of("chatgpt.com"));

        assertEquals(2, client.fetchCount);
        assertEquals(List.of(), client.savedRequests);
    }

    @Test
    void failsVerificationWhenARequestedScopedRewriteIsMissingAfterSave() {
        StubRewriteClient client = client(List.of(), List.of());
        NextDnsRewriteService service = service(client);
        Map<String, CreateRewriteDto> desiredRequests = Map.copyOf(requests(
                request("chatgpt.com", "193.233.112.1")
        ));

        List<CreateRewriteDto> toCreate = service.cleanupOutdatedAndExcluded(
                new LinkedHashMap<>(desiredRequests),
                List.of("chatgpt.com")
        );
        service.saveRewrites(toCreate);
        UserInputException exception = assertThrows(
                UserInputException.class,
                () -> service.verifySynchronizedRewrites(desiredRequests, List.of("chatgpt.com"))
        );

        assertEquals(List.of(request("chatgpt.com", "193.233.112.1")), client.savedRequests);
        assertEquals(2, client.fetchCount);
        assertTrue(exception.getMessage().contains("missing requested rewrites"));
    }

    @Test
    void failsVerificationWhenAnObsoleteScopedRewriteRemains() {
        RewriteDto root = rewrite("root", "chatgpt.com", "193.233.112.1");
        RewriteDto obsolete = rewrite("obsolete", "ws.chatgpt.com", "87.228.47.204");
        StubRewriteClient client = client(List.of(root, obsolete), List.of(root, obsolete));
        NextDnsRewriteService service = service(client, List.of("api.chatgpt.com"));
        Map<String, CreateRewriteDto> desiredRequests = Map.copyOf(requests(
                request("chatgpt.com", "193.233.112.1"),
                request("api.chatgpt.com", "193.233.112.3")
        ));

        List<CreateRewriteDto> toCreate = service.cleanupOutdatedAndExcluded(
                new LinkedHashMap<>(desiredRequests),
                List.of("chatgpt.com")
        );
        service.saveRewrites(toCreate);
        UserInputException exception = assertThrows(
                UserInputException.class,
                () -> service.verifySynchronizedRewrites(desiredRequests, List.of("chatgpt.com"))
        );

        assertEquals(List.of("obsolete"), client.deletedIds);
        assertEquals(List.of(), client.savedRequests);
        assertEquals(2, client.fetchCount);
        assertTrue(exception.getMessage().contains("unexpected or excluded rewrites"));
    }

    @Test
    void failsVerificationWhenARequestedScopedRewriteHasTheWrongContent() {
        RewriteDto outdatedRoot = rewrite("root", "chatgpt.com", "87.228.47.204");
        StubRewriteClient client = client(List.of(outdatedRoot), List.of(outdatedRoot));
        NextDnsRewriteService service = service(client);
        CreateRewriteDto desiredRoot = request("chatgpt.com", "193.233.112.1");
        Map<String, CreateRewriteDto> desiredRequests = Map.copyOf(requests(desiredRoot));

        List<CreateRewriteDto> toCreate = service.cleanupOutdatedAndExcluded(
                new LinkedHashMap<>(desiredRequests),
                List.of("chatgpt.com")
        );
        service.saveRewrites(toCreate);
        UserInputException exception = assertThrows(
                UserInputException.class,
                () -> service.verifySynchronizedRewrites(desiredRequests, List.of("chatgpt.com"))
        );

        assertEquals(List.of("root"), client.deletedIds);
        assertEquals(List.of(desiredRoot), client.savedRequests);
        assertTrue(exception.getMessage().contains("content mismatch"));
    }

    @Test
    void passesVerificationWhenExcludedRequestedRulesAreAbsent() {
        RewriteDto root = rewrite("root", "chatgpt.com", "193.233.112.1");
        StubRewriteClient client = client(List.of(root), List.of(root));
        NextDnsRewriteService service = service(client, List.of("api.chatgpt.com"));
        Map<String, CreateRewriteDto> desiredRequests = Map.copyOf(requests(
                request("chatgpt.com", "193.233.112.1"),
                request("api.chatgpt.com", "193.233.112.3")
        ));

        List<CreateRewriteDto> toCreate = service.cleanupOutdatedAndExcluded(
                new LinkedHashMap<>(desiredRequests),
                List.of("chatgpt.com")
        );
        service.saveRewrites(toCreate);

        service.verifySynchronizedRewrites(desiredRequests, List.of("chatgpt.com"));

        assertEquals(List.of(), client.savedRequests);
        assertEquals(2, client.fetchCount);
    }

    private static StubRewriteClient client(RewriteDto... existingRewrites) {
        return new StubRewriteClient(List.of(existingRewrites), null);
    }

    private static StubRewriteClient client(
            List<RewriteDto> existingRewrites,
            List<RewriteDto> verificationRewrites
    ) {
        return new StubRewriteClient(existingRewrites, verificationRewrites);
    }

    private static NextDnsRewriteService service(StubRewriteClient client) {
        return service(client, List.of());
    }

    private static NextDnsRewriteService service(StubRewriteClient client, List<String> excludedDomains) {
        ExcludeRedirectCheckService excludeService = new ExcludeRedirectCheckService(new ExcludeRedirectSettingsLoader() {
            @Override
            public List<String> loadIgnoredDomains() {
                return excludedDomains;
            }
        });
        return new NextDnsRewriteService(client, excludeService);
    }

    private static RewriteDto rewrite(String id, String name, String content) {
        return new RewriteDto(id, name, content);
    }

    private static CreateRewriteDto request(String name, String content) {
        return new CreateRewriteDto(name, content);
    }

    private static Map<String, CreateRewriteDto> requests(CreateRewriteDto... requests) {
        Map<String, CreateRewriteDto> requestMap = new LinkedHashMap<>();
        for (CreateRewriteDto request : requests) {
            requestMap.put(request.name(), request);
        }
        return requestMap;
    }

    private static class StubRewriteClient extends NextDnsRewriteClient {

        private final List<RewriteDto> existingRewrites;
        private final List<RewriteDto> verificationRewrites;
        private final List<String> deletedIds = new ArrayList<>();
        private final List<CreateRewriteDto> savedRequests = new ArrayList<>();
        private int fetchCount;

        private StubRewriteClient(List<RewriteDto> existingRewrites, List<RewriteDto> verificationRewrites) {
            this.existingRewrites = existingRewrites;
            this.verificationRewrites = verificationRewrites;
        }

        @Override
        public List<RewriteDto> fetchRewrites() {
            fetchCount++;
            return fetchCount == 1 || verificationRewrites == null ? existingRewrites : verificationRewrites;
        }

        @Override
        public @Nullable SingleRewriteResponse deleteRewriteById(String id) {
            deletedIds.add(id);
            return null;
        }

        @Override
        public SingleRewriteResponse saveRewrite(CreateRewriteDto rewriteDto) {
            savedRequests.add(rewriteDto);
            return null;
        }
    }
}
