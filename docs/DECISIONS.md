# Decisions

D1-D3 agreed with the user 2026-11-06 ("3.9.16 first", product MAVEN, go ahead with
Phase 1); D4-D6 proposed.

## D1. Maven 3.9 first, on the nodes' Java 8

Both nodes have VSI OpenJDK 8 (IA64 1.8.0_502, x86-64 1.8.0_482). Maven 4 needs Java 17,
so it is out until a newer JDK is on both nodes. Maven 3.9.16 and 3.10.0 both run on Java 8;
3.9.16 is first because it works now (NOTES N1). 3.10.0 follows when its console output is
fixed (N3).

## D2. Source: upstream's signed binary distribution, patched jar by jar

The port starts from `apache-maven-<v>-bin.tar.gz` (SHA-512 and the release manager's
signature, keys from Apache's KEYS file), not a source build: building Maven needs Maven,
and almost every class is right as it is. A fix changes one class's source, taken from the
jar's signed `-sources.jar` on Maven Central; the class is compiled on the node and put
back into that jar. Patches are written to go upstream.

## D3. Product MAVEN

There is no VSI Maven kit, so the PCSI product is ISSINOHO MAVEN with the concealed rooted
logical MAVEN$ROOT (layout in Phase 4). Kit: ISSINOHO-<I64VMS|X86VMS>-MAVEN-...-1.PCSI.

## D4. The launcher is a C image (proposed)

`MVN` is a foreign command for `MAVEN$ROOT:[BIN]MVN.EXE`, a C port of `bin/mvn`
(overlay/vmsport/mvn.c), because a DCL procedure gets its parameters upper-cased and at
most eight of them (N4). It starts Java with vfork/execv, so arguments reach Java without
DCL in between (N5), and returns Java's exit status.

## D5. Tests run in Maven's JVM by default (proposed)

surefire forks its test JVM through `/bin/sh` (N6). Until there is a better way, the kit's
`conf/settings.xml` sets `forkCount=0` in an active-by-default profile, and README.VMS says
what that changes (tests share Maven's JVM; System.exit in a test ends the build).

## D6. Versions and tags (proposed)

Tags v<upstream>-vms<N> (v3.9.16-vms1). PCSI version V3.9-16E<N>, as vms-vim's
three-part versions.
