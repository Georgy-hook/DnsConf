package com.novibe.dns.next_dns.http;

import com.novibe.common.http.ApiRequestSender;
import com.novibe.common.exception.CredentialsException;
import com.novibe.common.exception.DnsHttpError;
import com.novibe.common.util.Log;
import com.novibe.dns.next_dns.http.dto.response.NextDnsResponse;

import java.time.Duration;
import java.util.List;
import java.util.function.Function;

public abstract class AbstractNextDnsApiClient extends ApiRequestSender {

    private static final int RETRY_ATTEMPTS = 3;

    // NextDNS api rate limiter resets 60 seconds after the last request
    private static final Duration RETRY_DELAY = Duration.ofSeconds(60);

    protected abstract String path();

    @Override
    protected int retryAttempts() {
        return RETRY_ATTEMPTS;
    }

    @Override
    protected Duration retryDelay() {
        return RETRY_DELAY;
    }

    @Override
    protected String apiUrl() {
        return "https://api.nextdns.io/profiles/%s".formatted(dnsProfile.clientId());
    }

    @Override
    protected String authHeaderName() {
        return "X-Api-Key";
    }

    @Override
    protected String authHeaderValue() {
        return dnsProfile.authSecret();
    }

    @Override
    protected final void react401() {
        throw new CredentialsException("Invalid api key");
    }

    @Override
    protected void react403() {
        throw new CredentialsException("Invalid api key!");
    }

    @Override
    protected void react404(DnsHttpError dnsHttpError) {
        if (dnsProfile.clientId() != null) {
            Log.fail("Make sure that values of AUTH_SECRET and CLIENT_ID belongs to same account! Providing a new API Token to AUTH_SECRET may help.");
        }
        throw dnsHttpError;
    }

    /**
     * Sends a request per element, so the progress of long lists is visible in the log.
     * A missing response or an empty errors list counts as success.
     *
     * @return number of responses containing API errors
     */
    protected <D, R extends NextDnsResponse<?>> int callApiForEach(List<D> requestList, Function<D, R> request) {
        int succeeded = 0;
        for (D requestData : requestList) {
            R response = request.apply(requestData);
            if (response != null && response.getErrors() != null && !response.getErrors().isEmpty()) {
                Log.fail("Failed request: " + response.getErrors());
            } else {
                Log.progress("Current success progress: " + ++succeeded + "/" + requestList.size());
            }
        }
        int failed = requestList.size() - succeeded;
        if (failed == 0) {
            Log.common("\nCompleted");
        } else {
            Log.common("\nCompleted with %s requests failed of %s".formatted(failed, requestList.size()));
        }
        return failed;
    }

}
