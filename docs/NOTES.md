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

## N3. Maven 3.10.0 prints nothing to the terminal (cause found 2026-11-21)

3.10.0 runs (`-l file` shows its output) but writes nothing to SYS$OUTPUT, even with `-X`.
`-verbose:class` stops in jline's terminal setup (`org.jline.utils.OSUtils`, after the JNI
and exec terminal providers are tried). To look at with 3.10 (D1); `-Dorg.jline.terminal.dumb=true`
was not enough.

**Cause (x86-64, 2026-11-21).** 3.10.0 sets up a jline 3.30 terminal in the background
(maven-jline's FastTerminal) and replaces System.out with it. jline's exec provider
asks whether each stream is a terminal by running `test -t <fd>` with `inheritIO()`.
OpenVMS has no `test` program, and on VSI OpenJDK 8 a `ProcessBuilder.start()` of a
program that does not exist, **with the standard output set to INHERIT**, ends the JVM
on the spot: no exception, nothing more on either stream, status `%X10000001`. (The
same start without INHERIT throws "Cannot run program ... no such file or directory",
as it should. Probe class Probe: `test`/`nosuchcmd` with `inheritIO()` or
`redirectOutput(INHERIT)`.) So Maven ended silently after parsing its command line,
with a success status.

- `-Dorg.jline.terminal.provider=dumb` (or `-Dorg.jline.terminal.exec=false`) skips the
  exec provider: 3.10.0 then prints its output, colour off as in 3.9.
- In a PIPE the output then came a character to a record: jansi's AnsiOutputStream
  writes a byte at a time to an unbuffered FileOutputStream, and each write() was a
  record (N25). MVN.EXE's line relay (N25) puts the lines together again; buffering in
  jline's DumbTerminalProvider also worked, but is not needed with the relay.
- 3.10.0 ships maven-resolver 2.0.24, without patch 0001: `package` failed on
  "Failed to delete tracking file ... .lastUpdated ... file currently locked by another
  user" (N2). Patch 0001 has to be redone for resolver 2.

So a 3.10 port needs: the launcher to pass `-Dorg.jline.terminal.provider=dumb` (no
jline provider but dumb can work on OpenVMS: there is no native library, `tty`, `stty`
or `test`), patch 0001 for resolver 2.0.x, and the other patches checked against 3.10's
sources. The JVM ending on a failed INHERIT start is VSI's to fix (to report to VSI).

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

**Cause found: N21** (the file-lock factory's DELETE_ON_CLOSE; fixed in MVN.EXE).

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

## N20. Plugins that run programs or write many files (2026-11-11)

TEST_PLUGINS.COM (tests/plugins) on x86-64, first run: exec:java (in Maven's JVM,
300 files) passed; four failed, each for its own reason:

- **exec:exec** (exec-maven-plugin 3.5.0, commons-exec 1.4.0): commons-exec picks its
  VmsCommandLauncher from os.name, which writes the command as a DCL procedure. It
  writes each environment variable as `$ NAME == "` + newline + `VALUE"` (println
  where print was meant), so DCL runs `VALUE"` as a command: "%DCL-W-NOCOMD",
  "%DCL-E-PARSEFAIL, error parsing DCL$PATH:TRUE"". It also writes the program as a
  Unix path after `$ `, which DCL cannot run, unless the file exists (then `@` it as a
  procedure). Still so in commons-exec 1.6.0, the latest. No configuration avoids the
  launcher; exec:java, or antrun's <java>/<exec>, work. To be offered upstream.
- **antrun `<java fork="true">`** (Ant 1.10.12): JavaEnvUtils looks for
  java.home/bin/java, adds ".exe" only on DOS, so on OpenVMS (JAVA.EXE) falls back to
  "java", and ProcessBuilder fails: "Cannot run program "java" ... no such file or
  directory". Ant starts it directly (Java13CommandLauncher, not its DCL launcher).
  VSI's JAVA$EXEC_MAPPING_nn matches a bare program name too ("java=/.../java.exe"
  made ProcessBuilder("java") run Java), so MVN.EXE now maps java, javac, javadoc
  and jar to the JDK's images, as it maps /bin/sh (unless the site maps them).
  With that, <java fork> runs. On OpenVMS Ant always uses its shell launcher for it
  (Execute turns the VM launcher off for the os family "openvms"): VmsCommandLauncher
  writes `$ java -` and each argument unquoted on its own continuation line into an
  ANT*.COM, so an argument with a space arrives as two ("MixedCase Arg" ->
  "MixedCase", "Arg"); case was kept (the job has the EXTENDED parse style). The
  JVM itself passes such arguments intact (ProcessBuilder by path, by a mapped bare
  name, and through MVNSH, in either parse style). Known; a quoting fix for Ant's
  VmsCommandLauncher to be offered upstream.
- **javadoc:jar** (maven-javadoc-plugin 3.11.2): looks for java.home/../bin/javadoc
  (".exe" only on Windows): "Unable to find javadoc command". Patch 0003's openvms
  settings profile sets javadocExecutable to ${java.home}/../bin/javadoc.exe.
- **assembly tar.gz** (plexus-archiver 4.9.2): "user id '8388673' is too big
  ( > 2097151 )": the owner's UIC as one number does not fit the old tar header. The
  zip was fine. Patch 0003 sets assembly.tarLongFileMode=posix, with which
  plexus-archiver writes big ids (and long names) in pax headers.

## N21. The file-lock factory's DELETE_ON_CLOSE deleted Maven's open jars (2026-11-11)

The cause of N17. After a build, the local repository had the .pom, .sha1 and
_remote.repositories of every plugin and plugin dependency, but not the jar, so every
build downloaded them again (and failed when Maven Central was unreachable: the IA64
smoke test of 2026-11-11). Found with:

- an AUDIT=SECURITY ACE with OPTIONS=DEFAULT on a fresh repository (ALARM ACEs only go
  to OPCOM, and this system's OPERATOR.LOG is not written, so the "no records" of the
  first alarm runs, and of N17's tools.jar alarms, meant nothing): Maven's own java.exe
  deleted every jar of the plugins' class realms one after another, about 10 ms apart,
  as the JVM exited (Object deletion, by file ID, the jar's own);
- a SecurityManager on the boot classpath logging every checkDelete with its stack:
  no Java code asked to delete a jar (only temp files, .lastUpdated and lock files);
- builds into fresh repositories: with -Daether.named.file-lock.deleteLockFiles=false
  or with the rwlock-local factory, every jar survived; with the defaults, none did.

The resolver's file-lock factory opens each lock file with DELETE_ON_CLOSE. VSI's JVM
emulates that (its share layer has a delete_on_close), and in Maven's pattern of use
the delete lands on another file the JVM has open: the jars, deleted when the JVM
closes them at exit. Simple sequences (a DELETE_ON_CLOSE channel, then a jar opened and
left open; moves and deletes of temp files with streams open; class loaders, ZipFile,
JarFile and jar: URLs) did not reproduce it alone; to be reported to VSI with the
Maven case. tools.jar, loaded by in-process javac, went the same way while the account
held SYSPRV (the system protection category gives delete); the losses began with the
first file-lock runs (N16).

MVN.EXE keeps the cross-process file locks (N16) but passes
-Daether.named.file-lock.deleteLockFiles=false: the lock files stay in .locks as empty
files. A resolver patch that skipped deleting a temp file's name after moving it was
tried first and did not help.

## N22. settings.xml, toolchains.xml and the default local repository (2026-11-11)

`mvn -X` on x86-64: Maven reads `conf/settings.xml` and `conf/toolchains.xml` from its
home, and `~/.m2/settings.xml`, `~/.m2/toolchains.xml` and `~/.m2/repository`, where `~`
is user.home: SYS$LOGIN as a Unix path (`/DISK$USER/USERNAME/.m2/...`). TEST_CONFIG.COM
(tests/config) checks them in a test home given as user.home, not the account's own:

- **Default local repository:** `<user.home>/.m2/repository`. MVN.EXE creates it with a
  version limit of 1 (N19); it now takes user.home from the last `-Duser.home`, as
  Maven does, before HOME.
- **user.home and toolchains:** Maven reads the user toolchains path from user.home when
  it starts, so `-Duser.home` among Maven's arguments changes the settings and the
  repository but not `toolchains.xml`; given to the JVM (MAVEN_OPTS) it changes all.
  The same on every platform.
- **settings:** a profile in `~/.m2/settings.xml`, conf/settings.xml's openvms profile,
  and `-s <unix path>` all work. `-s [-.x]settings.xml` worked too, by accident: Maven
  puts the current directory in front (`/dev/dir/[-.x]settings.xml`, as -X shows), and
  the C RTL still resolves that. Give Unix paths.
- **JDK toolchain:** maven-toolchains-plugin found the toolchain, but
  `JavaToolchainImpl.findTool` (maven-core) adds ".exe" only on Windows, so it found no
  `bin/javac` and maven-compiler-plugin warned "Unable to autodetect 'javac' path,
  using 'javac' from the environment": the bare name, which MVN.EXE maps to the javac
  of the JDK Maven runs on (N20). With one JDK no harm; with a toolchain for another,
  the wrong compiler. Patch 0004 looks for `<tool>.exe` on OpenVMS too.
- DCL: without privileges F$PARSE gives "" for a directory it cannot look into (the
  JDK in [SYS0.SYSCOMMON]); SYNTAX_ONLY gives the parts.

## N23. A JVM that did not exit after BUILD SUCCESS (x86-64, 2026-11-11, open)

In one TEST_PLUGINS.COM run on x86-64, step 5 (`package assembly:single`, 5:55 min
where it usually takes about 1) printed BUILD SUCCESS at 22:10:15, and its JVM then sat
in LEF with no CPU or I/O for 35 minutes. jstack failed ("Premature EOF" from
VmsVirtualMachine.execute), and the JVM exited 3 s after that attach: the attach seems
to have woken it. The rerun took 8:40 in all and did not hang. Not seen on IA64. If it
comes back, look at the process with SHOW PROCESS/ID and ANALYZE/SYSTEM before any
attach, since the attach itself let it go.

## N24. Maven on a terminal: output, colour, startup time, CTRL/C and CTRL/Y (x86-64, 2026-11-21)

tools/ttytest.sh logs in over ssh in a pseudo-terminal and runs MVN from DCL.

- **Output** comes as Maven writes it, as on other systems. **Colour is off** on a
  terminal, in a PIPE and with -B; `-Dstyle.color=always` gives Maven's ANSI colours,
  which a VT terminal shows. (jansi has no native library for OpenVMS.) A SEARCH of a
  build log shows its matches in bold: that is SEARCH, not Maven.
- **Startup**: `mvn -v` takes 8.5 s; a one-module `validate` 45-50 s, of which Maven
  reports 3 s. The rest comes before Maven's first log line, and the terminal makes no
  difference (a PIPE is the same). `-verbose:class` shows no stall, just about 3,700 classes
  at about 80 a second, and the Java subprocess had used 31 s of CPU after 20 s (several
  threads): it is CPU-bound class loading. `-XX:TieredStopAtLevel=1`, `-Xverify:none`,
  `-Xms64m` and all three together came out at 42-50 s, within the run-to-run noise
  (43-50 s for the same command). The JDK has no CDS archive (`-Xshare:on` fails). A
  `package` with a test is about 90 s.
- **CTRL/C** reaches Java itself (its C RTL takes the terminal's CTRL/C as SIGINT): the
  shutdown hooks run and Java exits 130. DCL echoes "Cancel" but leaves the launcher to
  finish. The launcher then exited 130, and under `_POSIX_EXIT` the C RTL gives exit
  codes of 128 and up the *success* severity (`exit(130)` is `%X0035A411`, `%C-S-`;
  `exit(1)` is `%X1035A00A`), so a stopped build looked as if it had worked. MVN.EXE
  now exits with the same code and the error severity (`%X1035A412` for 130), and
  makes a child killed by a signal 128 + the signal.
- **CTRL/Y** went to DCL, which interrupted MVN.EXE; the Java subprocess that
  vfork/execv made was gone at once, with no shutdown hooks, and `waitpid()` reported
  exit 0. CONTINUE then returned at once and `$STATUS` was success. (Running any image
  after CTRL/Y, e.g. SHOW PROCESS, also runs the interrupted image down; DCL built-ins
  such as WRITE do not.) Plain `java` from DCL survives CTRL/Y + CONTINUE: it is the
  vfork/execv child that dies. MVN.EXE now turns off DCL's CTRL/Y with
  `LIB$DISABLE_CTRL(LIB$M_CLI_CTRLY)` while Java runs, takes CTRL/Y itself with a
  `IO$M_CTRLYAST` on SYS$COMMAND, and sends Java SIGINT from the AST: CTRL/Y now
  stops Maven as CTRL/C does. It gives CTRL/Y back to DCL when Java ends (also as an
  atexit handler), and only from a terminal and only when CTRL/Y was on to begin with
  (SET NOCONTROL=Y is left alone). A user-mode CTRL/Y AST alone does not keep DCL from
  interrupting as well; disabling DCL's CTRL/Y alone makes CTRL/Y do nothing.
- The CTRL/Y setup must come **before** the vfork. Set up after Java had started, the
  AST's `kill(pid, SIGINT)` made Java exit 0 at once, without its hooks (shown with a
  test wrapper both ways round; the JVM options, the `JAVA$` settings, the C RTL features
  and `_POSIX_EXIT` made no difference).

- **DCL still sees the CTRL/Y, late.** With its CTRL/Y disabled DCL records the key and
  acts on it when MVN.EXE gives CTRL/Y back, after Java has stopped. MVN.EXE always
  saw Java end with 130 (`MAVEN_VMS_TRACE`: wait status `%X8200`, 1 CTRL/Y) and the
  process had no image left, but `$STATUS` at the prompt was then `%CLI-S-NORMAL` in 6
  runs of 8. In a command procedure, 4 runs of 5 were interrupted before the line after
  MVN (as CTRL/Y in a procedure normally is), and one read `%X00000001`. So CTRL/Y
  stops Maven cleanly (shutdown hooks, no subprocess left) and interrupts an enclosing
  procedure, but `$STATUS` after it is not reliable.
- **CTRL/C too (2026-11-21, later).** CTRL/C's `$STATUS` was `%X1035A412` in 10 runs out
  of 10 at first. Later the same day it was `%X00030001` in 4 of 7 runs with the N25
  launcher and in 3 of 3 with the launcher committed before it, while MVN.EXE always saw
  Java exit 130 (wait status `%X8200`). So DCL acts late on CTRL/C as well, and how often
  shows varies. ttytest checks the exit code MVN.EXE got from Java (`MAVEN_VMS_TRACE`) and
  prints `$STATUS` after both keys rather than checking it.

ttytest on x86-64 with this launcher: 11/11 twice, and 10/11 twice on the CTRL/Y status
above (version, build, plain output, success status, colour, CTRL/C and CTRL/Y: prompt
back, no subprocess left, CTRL/C's `%X1035A412`, DCL's CTRL/Y back afterwards); with the
CTRL/Y status shown rather than checked, 10 checks. IA64 was unreachable that night. Now 11 checks (Java exit 130 after each key
checked, `$STATUS` after each shown): 11/11 on x86-64.

## N25. An empty record after every line in a PIPE or batch log (x86-64, 2026-11-21)

`PIPE mvn ... > file` and a batch job's log had an empty record after each line Maven
logged (`DUMP/RECORD`: "[INFO] Scanning for projects..." then a 0-byte record). SEARCH
and the tests did not mind, but `TYPE` and a batch log showed every line double-spaced.
On a terminal the lines were right.

The cause is how VSI Java writes to a standard output it **inherits** through
vfork/execv. Probe class (Rec2: `print("a"); print("-b\n")`, `FileOutputStream` on
`FileDescriptor.out` with several writes per line, one byte at a time):

- `PIPE java -cp . Rec2 > f` (DCL starts the JVM): writes are joined up to each LF, one
  record per line, a byte at a time too.
- The same class under MVN.EXE (a Maven home whose `m2.conf` starts it), or under a
  ten-line vfork/execv test program: **one record per write()**, a write of just "\n" an
  empty record, a byte at a time one character per record. In a PIPE and a batch log
  alike. `decc$set_child_standard_streams(0, -1, -1)` and `(-1, -1, -1)` made no difference.
- `PrintStream.println(s)` writes `s` and then the line end, with a flush between them
  (an autoflush PrintStream flushes after each `write(byte[])`), hence the empty records.
  `DEFINE/USER SYS$OUTPUT file` was already right under MVN.EXE.

MVN.EXE now gives Java a C RTL pipe for its standard output when its own is not a
terminal, and copies what comes through to its own standard output with one `write()`
for each line. It points its fd 1 at the pipe with `dup2()` just for the vfork/execv and
then puts it back. (`decc$set_child_standard_streams(-1, pipe, -1)` also gave Java the
pipe, but once it is called Java opens its standard error by name: `PIPE mvn 2> file`
then got a new version of the file for Java, and the launcher's own messages stayed in the
old one.) The pipe gives Java's writes exactly (message by message) and ends when Java
exits (OpenVMS deletes Java's subprocesses with it, so nothing holds the pipe open after).
Records are then whole lines in a PIPE and a batch log, and the exit status is unchanged.
A partial line waits for its line end (or 32 KB); on a terminal there is no pipe, so a
prompt shows at once. The standard error is not relayed (Maven logs everything to the
standard output; a JVM error's lines may still be double-spaced in a log).

Under `DEFINE/USER SYS$OUTPUT file` there is no relay either: the records were already
whole lines there, and with the relay the images run after MVN in the same procedure lost
their output (DUMP and TYPE printed nothing; DCL's WRITE did). MVN.EXE looks for a
user-mode SYS$OUTPUT in the process table (`$TRNLNM`, `LNM$_ACMODE`). The smoke test's
`mvn -v` checks that its PIPE output has no empty record.

## N26. The PCSI kit (x86-64, 2026-11-21)

- Layout: the kit installs the Maven tree as [MAVEN] under the destination, with
  MAVEN$ROOT (concealed, rooted) for it, so MAVEN$ROOT:[000000] is the Maven home and
  MVN.EXE finds it as it does in a build tree (the parent of [.BIN]; `mvn -v` reports
  the physical path, /<device>/SYS0/SYSCOMMON/MAVEN). MAVEN$STARTUP.COM and
  MAVEN$SETUP.COM follow vms-vim's.
- Material: PCSI looks material up by name in one flat directory (vms-vim N17), and the
  tree has five README.txt, so tools/gen_kit.py gives every tree file a material name
  (Rnnnnn.DAT) and writes KIT_MATERIAL.COM, the COPYs MAKE_KIT.COM runs. Names like
  maven-core-3.9.16.jar go in the description as MAVEN-CORE-3^.9^.16.JAR.
- Names: PCSI installs every file in upper case. MVN.EXE finds plexus-classworlds
  without regard to case, but classworlds loads `lib/*.jar` by a case-sensitive match,
  and MAVEN-CORE-3^.9^.16.JAR does not end in ".jar". MAVEN$STARTUP.COM INSTALL runs
  MAVEN$CASE.COM (generated), which RENAMEs the 86 files with lower-case letters back
  (the extended parse style keeps the case). Directories keep upper-case names: Maven
  only looks them up, and renaming them needs delete access PCSI does not give
  (vms-vim N20).
- Left out: bin/mvn, mvn.cmd, mvnDebug, mvnDebug.cmd, mvnyjp and jansi's Windows DLLs,
  none of which can run here, and [.VMSPORT].
- First install check (tools/installcheck.sh): PRODUCT INSTALL took 20 s; all 51 jars
  have their real names; the smoke test passed 8/8 against MAVEN$ROOT:[BIN]MVN.EXE
  (TEST_SMOKE.COM's P1); PRODUCT REMOVE deassigned MAVEN$ROOT and left no files,
  no [MAVEN] directory and no startup procedure. %PCSI-I-CANNOTVAL: the kit is not
  signed, as in the rest of the family.
