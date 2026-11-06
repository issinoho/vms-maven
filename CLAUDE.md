# CLAUDE.md

Guidance for working in this repository: a port of Apache Maven to OpenVMS (IA64 and
x86-64) that stores only our changes over the upstream binary distribution. Read README.md
and docs/PLAN.md first; docs/DECISIONS.md (D1-D6) and docs/NOTES.md hold what has been
settled and found.

## Ground rules

- **Never edit `staging/`, `cache/` or `out/`.** They are regenerated. Every VMS change is
  either a patch (`patches/NNNN-*.patch`, listed in `patches/series`) or a new file in
  `overlay/`. `tools/prepare.sh` refuses overlay files that would replace upstream files.
- **Maven is Java: a patch changes the source of a class in one of the jars in `lib/`.**
  List the jar in `PATCHED_JARS` (upstream.conf) with the SHA-512 of its `-sources.jar` on
  Maven Central and its signing key (in `keys/`). Patch paths are
  `vmsport/src/<artifactId>/<package path>.java`; prepare.sh unpacks just the files the
  patches touch, and BUILD.COM compiles them on the node (`-source 8 -target 8`, against
  `lib/*`) and puts the classes into a fresh copy of the upstream jar. Make the patch with
  `diff -u a/<path> b/<path>`, with a `Subject:` line and the reason above it, and guard
  VMS-only behaviour with an `os.name` check so it can go upstream.
- **No JDK on the laptop:** everything Java is compiled on the nodes.
- **Plugins are not in the kit.** surefire, compiler, jar... come from Maven Central at
  build time, so they cannot be patched here; work around them in configuration
  (`conf/settings.xml`, documented) or offer fixes upstream.
- **Committed files must not contain real node details.** Use `<ia64-host>`, `<x86-host>`
  and `DISK$USER:[USERNAME.VMS_MAVEN]`. Real values live only in the git-ignored
  `tools/nodes.conf`.

## Commands

```sh
tools/prepare.sh                 # always first after changing patches/ or overlay/
tools/build.sh <ia64|x86> [ALL|CLEAN]   # MVN.EXE + patched jars
tools/test.sh <node>             # smoke test (batch job; needs Maven Central)
tools/vms.sh <node> dcl '<cmd>'  # run DCL; also run/batch/put/get
```

## VMS and Java pitfalls

- **MVN must be an image (foreign command), not `@MVN.COM`:** DCL upper-cases procedure
  parameters in both parse styles and allows only P1-P8; Maven's options and goals are
  case-sensitive (NOTES N4). Under the TRADITIONAL parse style (batch default) the CRTL
  lower-cases unquoted arguments of an image: the launcher notes it when Maven fails.
- **Java takes Unix paths only** (`/DISK$USER/USERNAME/...`); `[-]x.zip` is "no such file".
  Relative Unix paths resolve against the default directory.
- **OpenVMS cannot delete an open file** (patch 0001). Look for this first when a
  `FileSystemException: ... file currently locked by another user` appears.
- **Nothing can run `/bin/sh`**: anything that forks through a shell (surefire's forked
  tests) fails; `forkCount=0` runs tests in Maven's JVM.
- **A batch job starts in SYS$LOGIN**, not the work directory: procedures set their own
  default from `f$environment("procedure")`.
- **Don't name a DCL symbol after a command** you call (`jar = ...` replaced `JAR`).
- From the family: use `tools/vms.sh`, never raw `ssh`; never `WAIT` over ssh; never edit
  a running bash script; kill by explicit PID; `SYS$LOGIN:[.X]` is not valid on these
  nodes; `sftp put -r` nests (push.sh uploads file by file).

## Commits

Commit in logical steps with messages that explain the VMS reason for each change. Don't
push without the user asking; auto mode blocks public pushes, so hand the user a script.
