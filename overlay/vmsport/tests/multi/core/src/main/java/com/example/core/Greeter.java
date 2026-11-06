package com.example.core;

import org.apache.commons.lang3.StringUtils;

public final class Greeter {
    private Greeter() {}

    public static String greet(String who) {
        return "Hello, " + StringUtils.capitalize(who) + ", from a Maven reactor on OpenVMS";
    }
}
