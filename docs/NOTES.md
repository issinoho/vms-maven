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

## N10. GNV gives Java no /bin/sh on IA64

After `@SYS$COMMON:[GNV.LIB]GNV_SETUP.COM` in a batch job, GNV$GNU is still undefined and
surefire's fork fails the same way ("Child /bin/sh creation error"). IA64's GNV is bash
1.14 anyway. Not tried on x86-64.

## N11. forkCount=0 runs tests in the reactor root

With the tests in Maven's JVM, the working directory is the directory Maven was started
in, not the module's: in a reactor build, a test that writes `target/x` failed with
NoSuchFileException (core module of tests/multi). Forked test JVMs start in the module
directory. This is why the port forks (N12) rather than defaulting to forkCount=0.

## N12. /bin/sh through JAVA$EXEC_MAPPING; the job's page file quota

VSI's JVM (UNIXProcess_md.c in JAVA$JAVA_SHR) maps the program it is asked to start
through JAVA$EXEC_MAPPING_01, _02, ...: `"/bin/sh=/dev/dir/image.exe"` (execv) or
`"/bin/sh=DEV:[DIR]IMAGE.EXE"` (execvp) replaces argv[0]; a space or a search list does
not work. JAVA$EXEC_TRACE prints each start. A setenv() in the launcher reaches the JVM
as well as a logical name does. MVN.EXE maps /bin/sh to MVNSH.EXE, which runs the
`cd 'DIR' && 'PROGRAM' 'ARGS'` that plexus-utils' BourneShell builds; surefire's
forked JVM then starts, and its pipes work.

The forked JVM is a subprocess, and a subprocess draws on its job's pooled quotas. The
account's PGFLQUOTA is 504592 pagelets (about 246 MB) for the whole job; with Java 8's
defaults (152 MB max heap, 256 MB code cache reserved) the second JVM failed: "Could
not reserve enough space for object heap", then with smaller heaps "malloc failed",
ACCVIO, "OutOfMemoryError: Metaspace". Both JVMs fit with
Maven `-Xms16m -Xmx128m -XX:+UseSerialGC -XX:ReservedCodeCacheSize=32m` (MVN.EXE's
defaults) and the test JVM `-Xms8m -Xmx64m -XX:+UseSerialGC -XX:ReservedCodeCacheSize=16m`
(patch 0002's argLine). One run still failed with NoClassDefFoundError in the forked JVM,
most likely a jar it could not map for lack of quota. A larger PGFLQUOTA is the real fix
for bigger builds. The earlier "unable to create new native thread" during deploy is
probably the same limit.

## N13. DEFINE/USER SYS$OUTPUT with several processes

With forked tests, `DEFINE/USER SYS$OUTPUT x.out` + `mvn` left four versions of x.out:
each process in the chain opens SYS$OUTPUT itself, Maven's output was in ;3 and the
newest was empty. `PIPE mvn ... > x.out` (a mailbox) keeps it in one file; the tests and
README use PIPE.

## N14. The account's quotas are far below what Java wants

The reactor build (tests/multi) failed in the forked test JVM with `UnsatisfiedLinkError:
.../java$nio_shr: %RMS-E-ACC, ACP file access failed`: it could not open its own
shareable image, most likely because the job's open-file quota (FILLM 148, pooled like
PGFLQUOTA) was used up by Maven's JVM and its jars. HP's Java user guide recommends
FILLM 4096 and PGFLQUOTA 2097152 (plus larger BYTLM, BIOLM, DIOLM, TQELM); this account
has 148 and 504592. MVN.EXE now names the low quotas when a build fails. Raising them
(AUTHORIZE, then a new login) is for the system manager; the tests in Phase 2 wait on it.

## N15. File versions: VSI Java's JAVA$*_ALL_VERSIONS (2026-11-06)

With FILLM 4096 and PGFLQUOTA 2097152 the reactor build, shaded jar, install and deploy
pass. Two problems remained, both from file versions: after two installs the local
repository held 3 versions of core-1.0.jar, and `clean` failed ("Failed to delete
.../target/..."), since Java's delete removes only the newest version. VSI's JAVA$VMS_SHR
and JAVA$NIO_SHR read JAVA$DELETE_ALL_VERSIONS, JAVA$RENAME_ALL_VERSIONS and
JAVA$CREATE_DIR_WITH_OWNER_DELETE (HP's Java user guide: TRUE deletes/renames all versions;
new directories get owner delete). MVN.EXE now sets all three unless defined. Not yet
tested: see N17.

## N16. Two builds sharing a repository need the resolver's file locks

Two batch jobs filling one empty local repository: with the resolver's default
(in-JVM) locking one failed with `apache-33.pom.lastUpdated: file currently locked by
another user`; with `aether.syncContext.named.factory=file-lock` and
`nameMapper=file-gav` both passed. On Unix the race goes unnoticed; on OpenVMS another
process's open file cannot be opened for write. MVN.EXE now passes these as JVM
defaults (a user's -D overrides them).

## N17. tools.jar disappeared from the IA64 JDK (2026-11-06, 22:16-22:21)

`javac` and Maven's compiler stopped working: "Could not find or load main class
com.sun.tools.javac.Main". SYS$COMMON:[openjdk$80.lib]tools.jar, which PCSI lists for
OPENJDK80, is gone; the last compile that used it finished at 22:16:27 (the concurrent
builds of test_projects), and BUILD.COM's javac failed at 22:21. Nothing this port runs
deletes outside its work tree, and tools.jar was not moved into it; cause unknown, raised
with the user. Until it is restored, nothing that compiles Java runs on IA64.

2026-11-10, x86-64: it happened again on the first build and smoke test there. tools.jar
(15690 blocks, owner [SYSTEM], S:RWED,O:RWED,G:RE,W:RE) was present at 12:12; BUILD.COM's
javac used it at 12:13 and smoke step 2's `mvn package` compiled with it (finished
12:18:10, the step whose forked test JVM failed); javac failed at 12:33 and the file was
gone. No file of its size exists anywhere on the system or user disk, so it was deleted,
not renamed. Only step 2 compiled; later steps did not need tools.jar. Both losses came
from runs of MVN.EXE with JAVA$DELETE_ALL_VERSIONS / JAVA$RENAME_ALL_VERSIONS set (N15)
and a forked JVM, by an account whose processes hold SYSPRV (and BYPASS, READALL...),
which the system protection category gives delete access. The DCL in the tests deletes
only inside the work tree. ACL alarms are enabled on x86, so an alarm ACE on tools.jar
(ALARM=SECURITY, ACCESS=DELETE+SUCCESS+FAILURE) would name the process and image.

The tests now drop all privileges but NETMBX and TMPMBX (f$setprv, restored at the end;
the concurrent build jobs too), so a stray delete fails. With that alarm on IA64's
restored tools.jar, smoke (8/8) and the project tests (7/8) left it in place, and the
audit journal recorded no attempt to delete it. Both losses came in runs where something
failed (x86: the forked test JVM; IA64: the concurrent builds before N16's file locks),
so the delete is probably on a failure path. The one project failure: core-1.0.jar has 4 versions, but ;1-;3
are from 2026-11-06, before N15; a second install no longer adds one.
maven-metadata-local.xml still gets a new version on every install.

Later the same day, after tools.jar was restored on x86 (OPENJDK80 reinstalled, V8.0-502A,
OPENJDK17 removed), with the alarm on it too: x86 smoke 8/8 and projects 8/8, no delete
attempt recorded on either node. The old JDK is not the cause: IA64 was already on
V8.0-502A when it lost tools.jar, and never had OPENJDK17. Cause still unknown; the alarm
ACEs stay on both nodes' tools.jar so a future attempt is recorded (ANALYZE/AUDIT).

## N18. x86-64: forked test JVM's channel corrupted on OPENJDK80 V8.0-482A (2026-11-10)

The first x86 smoke test failed in `mvn package`: surefire reported "Corrupted channel by
directly writing to native stream in forked JVM 1" and "ForkStarter IOException: Stream
Closed", 0 tests run. The dump showed the forked JVM's binary event frames with their
0x0A length bytes missing (`:sys-prop:` then `:normal-run:` without the 0x0A between),
as if the pipe treated LF as a record end. IA64 (V8.0-502A) was fine. After OPENJDK80
was reinstalled as V8.0-502A and OPENJDK17 removed, the same test passed; which change
fixed it is unknown. README.VMS should ask for V8.0-502A or later.

## N19. File versions in the local repository: a version limit of 1 (2026-11-10)

N15's JAVA$DELETE_ALL_VERSIONS covers deletes, not rewrites: Java opening an existing
file for output creates a new version (FileOutputStream and NIO Files.write alike), and
so does a rename over an existing file. After the project tests the repository had
maven-metadata-local.xml;2-;8, .jar.sha1 files up to ;6, and ;2 of reinstalled jars and
poms. VSI's JVM reads JAVA$FILE_OPEN_MODE, but no value 0-4 changed this. A directory
created with /VERSION_LIMIT=1 does: in a probe, files rewritten three times (classic and
NIO) and a file replaced by temp + ATOMIC_MOVE each kept one version, and directories
Java created below it (File.mkdirs, Files.createDirectories) inherited the limit.
MVN.EXE now creates a missing local repository (the last maven.repo.local in Java's
options or Maven's arguments, else ~/.m2/repository) with the DEC C mkdir's version
limit argument; README.VMS gives the commands for an existing one. The project tests
count versions of core-1.0.jar and maven-metadata-local.xml after a second install. An existing tree takes
`SET DIRECTORY/VERSION_LIMIT=1 DEV:[REPO...]` (not `[REPO...]*.DIR`: "%SET-F-SYNTAX"),
and files already there keep "No version limit" until SET FILE/VERSION_LIMIT=1.
