# Ant: VmsCommandLauncher does not quote arguments, so one with a space is split

Draft for Apache Bugzilla, product Ant (component: Core tasks). Affects 1.10.12 and
master. Found porting Apache Maven to OpenVMS (maven-antrun-plugin 3.1.0).

## Summary

On OpenVMS, Ant always starts a forked program through `VmsCommandLauncher`, because
`Execute` turns off the VM launcher for the os family `openvms`.
`createCommandFile` writes each argument unquoted on its own DCL continuation line, so
DCL splits an argument at its spaces, and under the default parse style upper-cases it.

## Environment

- OpenVMS IA64 V8.4-2L3 and OpenVMS x86-64 E9.2-4
- VSI OpenJDK 1.8.0_502
- Ant 1.10.12 (maven-antrun-plugin 3.1.0); the code is the same on master

## What happens

```xml
<java classname="com.example.Tool" fork="true" classpath="...">
  <arg value="MixedCase Arg"/>
</java>
```

Ant writes `ANTnnnn.COM`:

```
$ java -
-classpath -
... -
com.example.Tool -
MixedCase Arg
```

The program gets two arguments, `MixedCase` and `Arg`. Case was kept here only
because the job has the EXTENDED parse style. Under TRADITIONAL, the default for
interactive processes and for batch jobs, the arguments arrive as `mixedcase` and
`arg`. Characters that mean something to DCL, such as `/`, `!`, `'` and `"`, break
an argument the same way.

The JVM itself passes such arguments intact. Started through `ProcessBuilder`, by
path or by a bare name mapped with VSI's `JAVA$EXEC_MAPPING_nn`, the program got
`MixedCase Arg` as one argument in either parse style.

Environment values have the same gap: `$ DEFINE/NOLOG NAME "value"` does not double a
`"` inside the value.

## Suggested fix

Not yet tested on OpenVMS; we can test a patch on both platforms.

```java
private static String dclQuote(String s) {
    return '"' + s.replace("\"", "\"\"") + '"';
}
...
out.write("$ " + cmd[0]);
for (int i = 1; i < cmd.length; i++) {
    out.write(" -");
    out.newLine();
    out.write(dclQuote(cmd[i]));
}
```

Use `dclQuote` for the `DEFINE` value as well. The C runtime strips the quotes when
the program starts, so programs see the argument as given, in either parse style. One
caution: DCL still substitutes `''symbol'` inside quotes, but a single `'` is left
alone.

A related problem: `JavaEnvUtils.getJreExecutable` and `getJdkExecutable` add `.exe`
only on DOS. On OpenVMS, `java.home/bin/java` does not exist (it is `JAVA.EXE`), so
Ant falls back to the bare name `java`, and `ProcessBuilder` cannot run it
("Cannot run program "java" ... no such file or directory") unless the site maps the
name. Adding `.exe` for the os family `openvms` too would fix that.
