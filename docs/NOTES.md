# Notes

Findings, numbered so commits and patches can refer to them.

## N1. Maven runs on VSI OpenJDK 8 (IA64, 2026-11-06)

`java -classpath boot/plexus-classworlds-2.11.0.jar ... Launcher -v` on IA64:
`Apache Maven 3.9.16`, `Java version: 1.8.0_502, vendor: VMS Software, Inc.`,
`OS name: "openvms", version: "v8.4-2l3", arch: "ia64", family: "openvms"`.
Java needs `@SYS$STARTUP:OPENJDK$SETUP.COM` first (network and batch logins don't run it).

## N2. Deleting an open file: the resolver's tracking files (patch 0001)

First real build (hello world, `package`): the plugin POM and its .sha1 downloaded from
Maven Central over TLS fine, then
`FileSystemException: ...maven-resources-plugin-3.4.0.pom.lastUpdated: file currently
locked by another user` from `DefaultTrackingFileManager.delete()` (resolver 1.9.27): it
deletes the file while its locked FileChannel is open. Patch 0001: on OpenVMS, close first.

## N3. Maven 3.10.0 prints nothing to the terminal

3.10.0 runs (`-l file` shows its output) but writes nothing to SYS$OUTPUT, even with `-X`.
`-verbose:class` stops in jline's terminal setup (`org.jline.utils.OSUtils`, after the JNI
and exec terminal providers are tried). To look at with 3.10 (D1); `-Dorg.jline.terminal.dumb=true`
was not enough.

## N4. DCL upper-cases procedure parameters

`@P.COM clean install -DskipTests "-Dquoted=Yes"` gives P1=CLEAN P2=INSTALL
P3=-DSKIPTESTS P4=-Dquoted=Yes under both EXTENDED and TRADITIONAL parse styles. Maven
would read `-DSKIPTESTS` and fail on `CLEAN`. Hence the image launcher (D4).

## N5. vfork/execv of JAVA.EXE

From a C image: the child Java inherits the process's JAVA$ logical names and symbols
(it starts), gets the argument strings exactly as passed (`-Dfoo=MixedCase`), and the
parent's waitpid() gives Java's exit code (System.exit(3) -> 3). The image's own argv is
case-preserved only with DECC$ARGV_PARSE_STYLE set (vms_crtl_init.c) and EXTENDED parse
style.

## N6. surefire forks through /bin/sh

`Cannot run program "/bin/sh" ... Child /bin/sh creation error: no such file or
directory` from ForkStarter. `-DforkCount=0` runs the tests in Maven's JVM and they pass
(JUnit 4.13.2). surefire also warned that it could not delete target/surefire (an open-file
delete again, as N2; harmless).

## N7. Paths

Java on VMS takes Unix paths only (`[-]mvn310.zip` is "no such file"); relative ones
resolve against the default directory. A batch job starts in SYS$LOGIN. Local repository
paths such as `org/apache/maven/plugins/maven-resources-plugin/3.4.0/` and names like
`maven-resources-plugin-3.4.0.pom.lastUpdated` work on ODS-5 (`3^.4^.0.DIR`).

## N8. DECC$FILE_SHARING in the launcher lost the output (2026-11-06)

With `DEFINE/USER SYS$OUTPUT x.out`, `mvn -v` left x.out;1 and ;2 empty, while PIPE and
plain output worked and the same vfork/execv from a test image without the family's
feature list worked. With DECC$FILE_SHARING set, the launcher's CRTL opens SYS$OUTPUT
shared, Java then writes into that same version, and the launcher's close at exit sets the
end-of-file back to 0. vms_crtl_init.c no longer sets it; Java now writes a new version.

## N9. Smoke test on IA64 (2026-11-06)

`tools/test.sh ia64`: 8 passed, 0 failed (mvn -v; package with download, javac, JUnit,
jar; the jar runs; -DskipTests keeps its case; error status on failure; .mvn base
directory, jvm.config and MAVEN_OPTS from a subdirectory; -f; the TRADITIONAL note).
Returning from main() is not mapped to a VMS status under _POSIX_EXIT (return 1 was
SS$_NORMAL): the launcher calls exit().
