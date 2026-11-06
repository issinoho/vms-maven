# Apache Maven for OpenVMS

![OpenVMS](https://img.shields.io/badge/OpenVMS-IA64%20%7C%20x86--64-blue)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)

[Apache Maven](https://maven.apache.org) (**3.9.16**) for OpenVMS on **IA64** and
**x86-64**, running on VSI OpenJDK 8. It belongs to the same family as
[GNU grep](https://github.com/issinoho/vms-grep), [curl](https://github.com/issinoho/vms-curl),
[Vim](https://github.com/issinoho/vms-vim) and the other
[vms-* ports](https://openvms.issinoho.com).

Maven is Java, so most of it runs on OpenVMS as it is. This repository holds **only our
changes** over the signed upstream binary distribution:

- **`MVN.EXE`**, a launcher that does what `bin/mvn` does (Maven home, Java, the `.mvn`
  project directory, `jvm.config`, `MAVEN_OPTS`). It is an image rather than a DCL
  procedure, so goals and options such as `-DskipTests` keep their case and there is no
  limit of eight parameters.
- **Patched classes** for the places where Maven assumes Unix or Windows file behaviour,
  compiled on the node and put back into the jar they came from. Each patch is written so
  it can go upstream.

**Status: in development** (docs/PLAN.md, Phase 1). There is no kit yet.

## Using it

```dcl
$ @SYS$STARTUP:OPENJDK$SETUP.COM          ! Java 8
$ SET PROCESS/PARSE_STYLE=EXTENDED       ! keep the case of arguments
$ MVN :== $DISK$USER:[USERNAME.VMS_MAVEN.APACHE-MAVEN-3_9_16.BIN]MVN.EXE
$ MVN -B package -DforkCount=0
```

- Under the TRADITIONAL parse style (the default, and what batch jobs get), arguments not in
  quotes reach Maven in lower case. The launcher prints a note when Maven then fails.
- surefire cannot fork its test JVM (it starts it through `/bin/sh`): use
  `-DforkCount=0` for now (docs/DECISIONS.md D5).
- `MAVEN_OPTS`, `MAVEN_ARGS`, `JAVA_HOME`, `MAVEN_HOME` and `MAVEN_BASEDIR` may be DCL
  symbols or logical names. `MAVEN_VMS_TRACE` prints the Java command line.

## Patches

| Patch | What | Why |
|---|---|---|
| 0001 | resolver: close a tracking file before deleting it | OpenVMS cannot delete an open file; every download failed (NOTES N2) |

## Building

```sh
tools/prepare.sh                 # fetch + verify, unpack, patch -> staging/
tools/build.sh <ia64|x86>        # MVN.EXE and the patched jars, on the node
tools/test.sh <node>             # smoke test (batch job, uses Maven Central)
```

`tools/nodes.conf` (from `nodes.conf.example`) names the nodes. Builds need VSI C and VSI
OpenJDK 8 on the node; nothing Java is compiled on the build host.

## Licence

Maven and its jars are under the Apache License 2.0 (see `LICENSE` and `lib/*.license` in
the distribution); our files are under the same licence.
