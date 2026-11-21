$! MAVEN$SETUP.COM - define the MVN command for a user
$!
$! Add to LOGIN.COM (or SYS$MANAGER:SYLOGIN.COM for everyone):
$!     $ @MAVEN$ROOT:[000000]MAVEN$SETUP.COM
$!
$! Maven runs on VSI OpenJDK 8: when neither the JAVA symbol nor JAVA_HOME is
$! defined, this runs SYS$STARTUP:OPENJDK$SETUP.COM.
$! Maven's goals and options are case-sensitive: use
$!     $ SET PROCESS/PARSE_STYLE=EXTENDED
$! or quote them ("-DskipTests").  See MAVEN$ROOT:[000000]README.VMS.
$!
$ if f$trnlnm("MAVEN$ROOT") .eqs. ""
$ then
$   write sys$error "MAVEN$SETUP: MAVEN$ROOT is not defined; run SYS$STARTUP:MAVEN$STARTUP.COM first"
$   exit 44
$ endif
$ mvn :== "$MAVEN$ROOT:[BIN]MVN.EXE"
$ if f$type(java) .nes. "" .or. f$type(java_home) .nes. "" .or. f$trnlnm("JAVA_HOME") .nes. "" -
    then exit 1
$ if f$search("SYS$STARTUP:OPENJDK$SETUP.COM") .nes. ""
$ then
$   @SYS$STARTUP:OPENJDK$SETUP.COM
$ else
$   write sys$error "MAVEN$SETUP: no Java; MVN needs VSI OpenJDK 8 (JAVA_HOME or the JAVA symbol)"
$ endif
$ exit 1
