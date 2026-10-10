package com.novibe.common.config;

import com.novibe.common.exception.UserInputException;

import static java.util.Objects.isNull;

public class EnvironmentVariables {

    public static final String DNS = extractMandatoryVariable("DNS");

    public static final String CLIENT_ID = extractMandatoryVariable("CLIENT_ID");

    public static final String AUTH_SECRET = extractMandatoryVariable("AUTH_SECRET");

    public static final String BLOCK = System.getenv("BLOCK");

    public static final String REDIRECT = System.getenv("REDIRECT");

    public static final String EXCLUDE_REDIRECT = System.getenv("EXCLUDE_REDIRECT");

    public static final String DONOR_DNS = System.getenv("DONOR_DNS");

    public static final String DONOR_DNS_DOMAINS = System.getenv("DONOR_DNS_DOMAINS");

    public static final String SYNC_REDIRECT_DOMAINS = System.getenv("SYNC_REDIRECT_DOMAINS");

    private static String extractMandatoryVariable(String key) {
        String env = System.getenv(key);
        if (isNull(env) || env.isBlank()) {
            throw UserInputException.noStackTrace("Mandatory environment variable is not provided: " + key);
        }
        return env;
    }

}
