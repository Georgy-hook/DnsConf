package com.novibe.dns.next_dns.http;

import com.novibe.common.exception.DnsApiException;
import com.novibe.dns.next_dns.http.dto.request.CreateDenyDto;
import com.novibe.dns.next_dns.http.dto.response.deny.DenyDto;
import com.novibe.dns.next_dns.http.dto.response.deny.MultiDenyResponse;
import com.novibe.dns.next_dns.http.dto.response.deny.SingleDenyResponse;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;

import java.util.List;

@Service
@RequiredArgsConstructor
public class NextDnsDenyClient extends AbstractNextDnsApiClient {

    public List<DenyDto> fetchDenylist() {
        return get(path(), MultiDenyResponse.class)
                .getData();
    }

    public void saveDenys(List<CreateDenyDto> denyDtos) {
        int failedRequests = callApiForEach(denyDtos, this::saveDeny);
        if (failedRequests > 0) {
            throw new DnsApiException("Failed to save NextDNS denylist entries: %s successful, %s failed of %s requests"
                    .formatted(denyDtos.size() - failedRequests, failedRequests, denyDtos.size()));
        }
    }

    public void deleteDenysByIds(List<String> ids) {
        callApiForEach(ids, this::deleteDenyById);
    }

    private SingleDenyResponse saveDeny(CreateDenyDto denyDto) {
        return post(path(), denyDto, SingleDenyResponse.class);
    }

    private SingleDenyResponse deleteDenyById(String id) {
        return delete(path() + "/" + id, SingleDenyResponse.class);
    }

    @Override
    protected String path() {
        return "/denylist";
    }

}
