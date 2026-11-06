# vms-maven: Apache Maven for OpenVMS, with a PCSI kit

## Goal

Apache Maven on IA64 and x86-64, on the Java the nodes have (VSI OpenJDK 8), installed and
removed with PRODUCT INSTALL / PRODUCT REMOVE like the rest of the family, and used the
way it is used elsewhere: `mvn clean install` in a project directory, with the local
repository in SYS$LOGIN:[.m2.repository] and artifacts from Maven Central.

Maven is pure Java, so there is nothing to compile for the port itself. The work is the
launcher (bin/mvn is a shell script), the places where Maven's code assumes Unix or
Windows file semantics, configuration for the plugins that fork processes, and the kit.

## Phase 0: feasibility (2026-11-06, done)

Probes on IA64 (NOTES N1-N7): Maven 3.9.16 and 3.10.0 run on Java 8; 3.9.16 builds,
tests and packages a hello-world project from Maven Central with patch 0001 and
`-DforkCount=0`. x86-64 was not reachable (ssh refused).

## Phase 1: repository, launcher, first patch (started 2026-11-06)

- Repo with the family tooling (from vms-vim): fetch.sh verifies the distribution and the
  sources jars (SHA-512 + signature), prepare.sh, push.sh, build.sh, test.sh, vms.sh.
- Patch 0001 (N2), compiled into lib/maven-resolver-impl-1.9.27.jar by BUILD.COM.
- MVN.EXE (D4): Maven home, Java, .mvn base directory, jvm.config, MAVEN_OPTS,
  MAVEN_ARGS, exit status, the TRADITIONAL parse style note.
- Smoke test (test_smoke.com): mvn -v, package, the jar runs, case kept, error status,
  base directory + jvm.config + MAVEN_OPTS, -f, the parse style note.

Status 2026-11-06: done on IA64: build clean, smoke test 8/8 (NOTES N8, N9). x86-64
not yet (ssh to it refused).

Exit: build and smoke test pass on both nodes; the user signs off D4-D6.

## Phase 2: Maven on real projects

- Default `conf/settings.xml` with forkCount=0 (D5); look for a way to keep forking (a
  surefire `jvm` setting that runs java directly, or a fix offered upstream).
- Multi-module reactor builds; `install` into the local repository; `deploy` to a file
  repository; plugins that fork (exec, antrun) and ones that write many files (shade,
  assembly, javadoc).
- Two Maven processes sharing one local repository (resolver's file locks, N2).
- Default local repository in SYS$LOGIN:[.m2]; settings.xml and toolchains.xml in
  ~/.m2 and conf/.
- Interactive use from a terminal: output, colour off, CTRL/C and CTRL/Y.
- 3.10.0's terminal output (N3).
- Record failures in NOTES; patch what is Maven's, document what is a plugin's.

## Phase 3: the kit

- PCSI kit ISSINOHO MAVEN (D3, D6): the distribution with the patched jars, MVN.EXE,
  MAVEN$STARTUP.COM (MAVEN$ROOT), MAVEN$SETUP.COM (MVN symbol, needs Java), README.VMS.
- tools/kit.sh and tools/installcheck.sh (install, smoke test, clean removal) on both nodes.

## Phase 4: release

- The family release process: tag v3.9.16-vms1, GitHub release with both kits and
  SHA256SUMS, entry in vms-grep/site/projects.json and the vms-grep README.
