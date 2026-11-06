package com.example;
import org.junit.Test; import static org.junit.Assert.*;
public class HelloTest { @Test public void says() { assertTrue(Hello.msg().contains("OpenVMS")); } }
