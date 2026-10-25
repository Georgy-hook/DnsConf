package com.novibe.dns.next_dns;

import com.novibe.common.base_structures.BypassRoute;
import com.novibe.common.base_structures.DnsProfile;
import com.novibe.common.data_sources.HostsBlockListsLoader;
import com.novibe.common.data_sources.HostsOverrideListsLoader;
import com.novibe.common.exception.UserInputException;
import com.novibe.dns.next_dns.http.dto.request.CreateRewriteDto;
import com.novibe.dns.next_dns.service.NextDnsDenyService;
import com.novibe.dns.next_dns.service.NextDnsRewriteService;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class NextDnsTaskRunnerTest {

    @Test
    void pinnedRootsAreSynchronizedEvenWithoutAnExplicitSyncScope() {
        List<String> events = new ArrayList<>();
        NextDnsRewriteService service = new StubRewriteService(events) {
            @Override
            public void verifySynchronizedRewrites(Map<String, CreateRewriteDto> desired, List<String> roots) {
                assertEquals(List.of("oaiusercontent.com"), roots);
                assertEquals(Map.of("oaiusercontent.com", new CreateRewriteDto("oaiusercontent.com", "45.13.237.213")), desired);
                super.verifySynchronizedRewrites(desired, roots);
            }
        };
        NextDnsTaskRunner runner = new NextDnsTaskRunner(service, new StubDenyService(events));
        runner.setDnsProfile(DnsProfile.builder().build());
        runner.setOverrideListsLoader(new HostsOverrideListsLoader() {
            @Override public List<BypassRoute> fetchWebsites(List<String> urls) {
                return List.of(new BypassRoute("193.233.112.88", "sdmntprwestus.oaiusercontent.com"));
            }
        });
        runner.process(List.of(), List.of("https://redirect.example/list"), List.of(),
                List.of(new BypassRoute("45.13.237.213", "oaiusercontent.com")));
        assertEquals(List.of("rewrite.build", "rewrite.cleanup", "rewrite.save", "rewrite.verify"), events);
    }

    @Test
    void rejectsConfiguredScopeWithoutAnySourcesBeforeServiceCalls() {
        List<String> events = new ArrayList<>();
        NextDnsTaskRunner runner = runner(events);

        assertThrows(
                UserInputException.class,
                () -> runner.process(List.of(), List.of(), List.of("chatgpt.com"))
        );

        assertEquals(List.of(), events);
    }

    @Test
    void rejectsConfiguredScopeBeforeApplyingBlockSourcesWhenRedirectSourcesAreMissing() {
        List<String> events = new ArrayList<>();
        NextDnsTaskRunner runner = runner(events);

        assertThrows(
                UserInputException.class,
                () -> runner.process(List.of("https://block.example/list"), List.of(), List.of("chatgpt.com"))
        );

        assertEquals(List.of(), events);
    }

    @Test
    void emptyScopeKeepsLegacyClearAllBehaviorWhenNoSourcesAreConfigured() {
        List<String> events = new ArrayList<>();
        NextDnsTaskRunner runner = runner(events);

        runner.process(List.of(), List.of(), List.of());

        assertEquals(List.of("deny.removeAll", "rewrite.removeAll"), events);
    }

    @Test
    void rejectsMissingSyncRootBeforeApplyingBlockSources() {
        List<String> events = new ArrayList<>();
        NextDnsTaskRunner runner = runner(events);
        runner.setOverrideListsLoader(new HostsOverrideListsLoader() {
            @Override
            public List<BypassRoute> fetchWebsites(List<String> urls) {
                events.add("redirect.fetch");
                return List.of(new BypassRoute("1.2.3.4", "chatgpt.com"));
            }
        });
        runner.setBlockListsLoader(new HostsBlockListsLoader() {
            @Override
            public List<String> fetchWebsites(List<String> urls) {
                events.add("block.fetch");
                return List.of("example.org");
            }
        });

        assertThrows(
                UserInputException.class,
                () -> runner.process(
                        List.of("https://block.example/list"),
                        List.of("https://redirect.example/list"),
                        List.of("chatgpt.com", "openai.com")
                )
        );

        assertEquals(List.of("redirect.fetch", "rewrite.build"), events);
    }

    @Test
    void rejectsRedirectFetchFailureBeforeApplyingBlockSources() {
        List<String> events = new ArrayList<>();
        NextDnsTaskRunner runner = runner(events);
        runner.setOverrideListsLoader(new HostsOverrideListsLoader() {
            @Override
            public List<BypassRoute> fetchWebsites(List<String> urls) {
                events.add("redirect.fetch");
                throw UserInputException.noStackTrace("redirect source unavailable");
            }
        });
        runner.setBlockListsLoader(new HostsBlockListsLoader() {
            @Override
            public List<String> fetchWebsites(List<String> urls) {
                events.add("block.fetch");
                return List.of("example.org");
            }
        });

        assertThrows(
                UserInputException.class,
                () -> runner.process(
                        List.of("https://block.example/list"),
                        List.of("https://redirect.example/list"),
                        List.of("chatgpt.com")
                )
        );

        assertEquals(List.of("redirect.fetch"), events);
    }

    private static NextDnsTaskRunner runner(List<String> events) {
        NextDnsTaskRunner runner = new NextDnsTaskRunner(new StubRewriteService(events), new StubDenyService(events));
        runner.setDnsProfile(DnsProfile.builder().build());
        return runner;
    }

    private static class StubDenyService extends NextDnsDenyService {

        private final List<String> events;

        private StubDenyService(List<String> events) {
            super(null);
            this.events = events;
        }

        @Override
        public List<String> omitExistingDenys(List<String> newDenyList) {
            events.add("deny.omit");
            return newDenyList;
        }

        @Override
        public void saveDenyList(List<String> newDenyList) {
            events.add("deny.save");
        }

        @Override
        public void removeAll() {
            events.add("deny.removeAll");
        }
    }

    private static class StubRewriteService extends NextDnsRewriteService {

        private final List<String> events;

        private StubRewriteService(List<String> events) {
            super(null, null);
            this.events = events;
        }

        @Override
        public void removeAll() {
            events.add("rewrite.removeAll");
        }

        @Override
        public Map<String, CreateRewriteDto> buildNewRewrites(List<BypassRoute> overrides) {
            events.add("rewrite.build");
            return super.buildNewRewrites(overrides);
        }

        @Override
        public List<CreateRewriteDto> cleanupOutdatedAndExcluded(
                Map<String, CreateRewriteDto> newRewriteRequests,
                List<String> synchronizedDomains
        ) {
            events.add("rewrite.cleanup");
            return List.of();
        }

        @Override
        public void saveRewrites(List<CreateRewriteDto> createRewriteDtos) {
            events.add("rewrite.save");
        }

        @Override
        public void verifySynchronizedRewrites(
                Map<String, CreateRewriteDto> desiredRequests,
                List<String> synchronizedDomains
        ) {
            events.add("rewrite.verify");
        }
    }
}
