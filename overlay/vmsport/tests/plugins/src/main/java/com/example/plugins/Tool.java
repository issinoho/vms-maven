package com.example.plugins;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.Arrays;
import org.apache.commons.lang3.StringUtils;

/**
 * What the plugin tests run: {@code gen DIR N} writes N small files into DIR;
 * anything else prints its arguments, working directory and a commons-lang3 call,
 * so the test sees that the program ran with its arguments and classpath.
 */
public final class Tool {
    private Tool() {
    }

    /**
     * Runs the tool.
     *
     * @param args {@code gen DIR N}, or any words to print
     * @throws IOException if a file cannot be written
     */
    public static void main(String[] args) throws IOException {
        if (args.length == 3 && args[0].equals("gen")) {
            File dir = new File(args[1]);
            dir.mkdirs();
            int n = Integer.parseInt(args[2]);
            for (int i = 0; i < n; i++) {
                try (FileOutputStream o = new FileOutputStream(new File(dir, "f" + i + ".txt"))) {
                    o.write(("file " + i + "\n").getBytes("UTF-8"));
                }
            }
            System.out.println("Tool: generated " + n + " files");
            return;
        }
        String cwd = new File(".").getCanonicalFile().getName();
        System.out.println("Tool: " + StringUtils.join(Arrays.asList(args), "|")
                + " in " + cwd + ", " + StringUtils.capitalize("lang3 ok"));
    }
}
