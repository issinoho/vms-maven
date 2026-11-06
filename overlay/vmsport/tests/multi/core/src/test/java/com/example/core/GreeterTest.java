package com.example.core;

import static org.junit.Assert.assertEquals;
import java.io.File;
import java.nio.file.Files;
import org.junit.Test;

public class GreeterTest {
    @Test public void capitalises() {
        assertEquals("Hello, World, from a Maven reactor on OpenVMS", Greeter.greet("world"));
    }

    /* Tests run in Maven's JVM (forkCount=0): basedir is the module. */
    @Test public void writesUnderTarget() throws Exception {
        File f = new File("target/greeter-test.txt");
        Files.write(f.toPath(), Greeter.greet("file").getBytes("UTF-8"));
        assertEquals(Greeter.greet("file"), new String(Files.readAllBytes(f.toPath()), "UTF-8"));
    }
}
