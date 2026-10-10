package com.novibe.dns.next_dns;

import com.novibe.common.base_structures.BypassRoute;
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

    private static NextDnsTaskRunner runner(List<String> events) {
        return new NextDnsTaskRunner(new StubRewriteService(events), new StubDenyService(events));
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
            return Map.of();
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
