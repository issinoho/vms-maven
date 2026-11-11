# VSI OpenJDK: a DELETE_ON_CLOSE file channel leads to the JVM deleting other open files at exit

Draft for VMS Software, Inc. (OpenJDK support). Found porting Apache Maven 3.9.16 to
OpenVMS.

## Summary

Apache Maven's resolver opens lock files with `StandardOpenOption.DELETE_ON_CLOSE`.
When a Maven run uses those lock files, the JVM deletes the jars it has open as it exits.
No Java code asks for these deletes. The jars are those of Maven's plugins, and, for
an account with SYSPRV, the JDK's own `SYS$COMMON:[OPENJDK$80.LIB]TOOLS.JAR`, which
Maven's in-process `javac` loads. With the lock files opened without DELETE_ON_CLOSE,
nothing is lost.

## Environment

- OpenVMS IA64 V8.4-2L3 and OpenVMS x86-64 E9.2-4
- VSI OpenJDK 1.8.0_502 (`Java version: 1.8.0_502, vendor: VMS Software, Inc.`)
- Apache Maven 3.9.16, with Maven Resolver 1.9.27
- JAVA$DELETE_ALL_VERSIONS, JAVA$RENAME_ALL_VERSIONS and
  JAVA$CREATE_DIR_WITH_OWNER_DELETE all set to TRUE

## How to reproduce

1. Start with an empty local repository and a one-module project that compiles a
   class (`mvn -B package`, maven-compiler-plugin 3.15.0).
2. Run Maven with the resolver's file locks:

   ```
   -Daether.syncContext.named.factory=file-lock
   -Daether.syncContext.named.nameMapper=file-gav
   ```

3. After the run, the repository has each plugin's `.pom`, `.sha1` and
   `_remote.repositories`, but none of the plugin jars or the jars they depend on (48
   jars in our test). The next run downloads them all again.
4. Run it again with `-Daether.named.file-lock.deleteLockFiles=false` added. The
   resolver then opens the lock files without DELETE_ON_CLOSE, and every jar is still
   there after the run. The same is true with the default lock factory
   (`rwlock-local`), which uses no lock files.

## What we found

- **Audit journal:** an `AUDIT=SECURITY,ACCESS=DELETE+SUCCESS+FAILURE` ACE with
  `OPTIONS=DEFAULT` on a new repository directory recorded Maven's own `JAVA.EXE`
  deleting every jar of the plugins' class loaders. The deletes came one after
  another, about 10 ms apart, as the JVM exited. Each was an object deletion, by file
  ID, of the jar itself.
- **SecurityManager:** a SecurityManager on the boot class path logged every
  `checkDelete` with its stack. No Java code asked to delete a jar; only temporary
  files, `.lastUpdated` files and the lock files were deleted from Java.
- **tools.jar:** the same thing deleted `TOOLS.JAR` on both nodes while the account
  held SYSPRV. The system protection category gives delete access, so the
  delete was allowed. The losses began with the first runs that used file locks.

Our reading: the JVM's emulation of DELETE_ON_CLOSE, done in the share layer at close
or at exit, applies to files other than the lock file, here the jars the JVM has open.

## What did not reproduce it

On their own, none of these lost a file:

- a DELETE_ON_CLOSE channel, then a jar opened and left open
- moves and deletes of temporary files with streams open
- class loaders, `ZipFile`, `JarFile` and `jar:` URLs

So we have no small test case yet, only the Maven one above, which reproduces it every
time on both platforms. We can run any build or tracing you would like.

## Impact

A user's jars, or with SYSPRV a system file, are deleted silently. Any Java program
that uses DELETE_ON_CLOSE could be affected. Our Maven launcher now passes
`deleteLockFiles=false` as a workaround.
