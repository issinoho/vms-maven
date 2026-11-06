package com.example.app;

import com.example.core.Greeter;
import java.io.InputStream;
import java.util.Properties;

public class Main {
    public static void main(String[] args) throws Exception {
        Properties p = new Properties();
        try (InputStream in = Main.class.getResourceAsStream("/app.properties")) {
            p.load(in);
        }
        System.out.println(Greeter.greet(args.length > 0 ? args[0] : "world")
                + " (app " + p.getProperty("app.version") + ")");
    }
}
