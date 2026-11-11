# Commons Exec: VmsCommandLauncher writes a DCL procedure that cannot run

Draft for Apache Jira, project EXEC (component: launcher). Affects 1.4.0 to 1.6.0 and
master. Found porting Apache Maven to OpenVMS (exec-maven-plugin 3.5.0, `exec:exec`).

## Summary

On OpenVMS, `VmsCommandLauncher.createCommandFile` writes the command into a temporary
DCL procedure. Any command run with an environment fails, since every environment
variable is written over two lines. A command given as a Unix path, which is the usual
case, does not run either.

## Environment

- OpenVMS IA64 V8.4-2L3 and OpenVMS x86-64 E9.2-4
- VSI OpenJDK 1.8.0_502
- commons-exec 1.4.0, through exec-maven-plugin 3.5.0; the code is the same in 1.6.0
  and on master

## What happens

1. **Each environment variable is split across two lines.** The opening quote is
   written with `println`:

   ```java
   writer.print(" == "); // define as global symbol
   writer.println('\"');      // <- should be print
   ```

   so the procedure reads

   ```
   $ PATH == "
   /usr/bin..."
   ```

   DCL runs the second line as a command: `%DCL-W-NOCOMD`, then
   `%DCL-E-PARSEFAIL, error parsing DCL$PATH:TRUE"`. exec-maven-plugin always passes
   an environment, so `exec:exec` never runs.

2. **A quote at the start of a value is not doubled.** The test is
   `value.indexOf('\"') > 0`, which skips a value whose first character is `"`. It
   should be `>= 0`.

3. **A program given as a Unix path does not run.** When the file does not exist,
   the procedure gets `$ /path/to/program`, and DCL cannot run a Unix path. When it
   does exist, `isFile()` makes it `$ @dev:[dir]program`, which runs a DCL procedure,
   not an image. So an image such as `/sys$common/openjdk$80/bin/java.exe` is run
   with `@`, which doesn't work either.

4. **Arguments are not quoted.** Each one is written bare on a continuation line.
   DCL upper-cases unquoted text (under the default TRADITIONAL parse style) and splits
   it at spaces, and characters such as `/`, `!` and `'` mean something to DCL.

## How to reproduce

```xml
<plugin>
  <groupId>org.codehaus.mojo</groupId>
  <artifactId>exec-maven-plugin</artifactId>
  <version>3.5.0</version>
  <configuration>
    <executable>java</executable>
    <arguments><argument>-version</argument></arguments>
  </configuration>
</plugin>
```

Run `mvn exec:exec` on OpenVMS. The build fails, with the DCL errors above in the output.

## Suggested fix

Not yet tested on OpenVMS; we can test a patch on both platforms.

- Write the opening quote with `print`, and double every `"` in the value
  (`value.replace("\"", "\"\"")`).
- Quote every argument the same way: `"` + doubled quotes + `"`. A quoted argument
  keeps its case and its spaces, and the C runtime strips the quotes when the program
  starts.
- Run an image through a foreign command, which takes a VMS file specification:

  ```
  $ cmd_ := $dev:[dir]program.exe
  $ cmd_ "arg1" "arg2"
  ```

  Keep `@` for files ending in `.COM`, and leave a bare name such as `java` as it is,
  so DCL$PATH or a defined command can find it. The Unix-to-VMS path conversion could
  stay as it is (`/dev/dir/sub/file` to `dev:[dir.sub]file`).

## Workaround

None by configuration: the launcher is chosen from `os.name`. On OpenVMS use
`exec:java`, or antrun's `<java>`, instead.
