$! MAVEN$STARTUP.COM - system startup for Apache Maven on OpenVMS
$!
$! Installed by PCSI into SYS$STARTUP.  Defines the system logical name
$! MAVEN$ROOT, the installed [MAVEN] directory (the Maven home), concealed.
$! To run it at every boot, add this line to SYS$MANAGER:SYSTARTUP_VMS.COM:
$!
$!     $ @SYS$STARTUP:MAVEN$STARTUP.COM
$!
$! P1 = "INSTALL": also give the files their real names (PCSI installs them in
$!                 upper case) and print the post-installation tasks; PCSI
$!                 runs it so.
$! P1 = "REMOVE":  deassign MAVEN$ROOT instead (PCSI runs it so).
$!
$! Users then define the MVN command with
$!     $ @MAVEN$ROOT:[000000]MAVEN$SETUP.COM
$!
$ set noon
$ mode = f$edit(p1, "UPCASE")
$ if mode .eqs. "REMOVE"
$ then
$   if f$trnlnm("MAVEN$ROOT", "LNM$SYSTEM_TABLE") .nes. "" then -
        deassign/system/executive_mode MAVEN$ROOT
$   exit 1
$ endif
$!
$! This procedure sits in <destination>[SYS$STARTUP]; the product is in
$! <destination>[MAVEN].  Rooted logicals need the physical form:
$! DKA0:[SYS0.SYSCOMMON.SYS$STARTUP] -> DKA0:[SYS0.SYSCOMMON.MAVEN.]
$ proc = f$environment("PROCEDURE")
$ dev = f$parse(proc,,,"DEVICE","NO_CONCEAL")
$ dir = f$edit(f$parse(proc,,,"DIRECTORY","NO_CONCEAL"), "UPCASE") - "]["
$ root = dir - "SYS$STARTUP]" + "MAVEN.]"
$ if root .eqs. dir + "MAVEN.]"
$ then
$   write sys$error "MAVEN$STARTUP: expected to be in a [SYS$STARTUP] directory, not ''dir'"
$   exit 44
$ endif
$ root = root - ".000000"
$ define/system/executive_mode/translation_attributes=concealed MAVEN$ROOT 'dev''root'
$ if f$search("MAVEN$ROOT:[BIN]MVN.EXE") .eqs. ""
$ then
$   write sys$error "MAVEN$STARTUP: MVN.EXE not found under ''dev'''root'"
$   exit 44
$ endif
$ if mode .nes. "INSTALL" then exit 1
$!
$! PCSI stores every file name in upper case; classworlds loads lib/*.jar
$! by a case-sensitive match.  MAVEN$CASE.COM gives each file its real name.
$! (The directories keep upper-case names: Maven only looks them up.)
$ @MAVEN$ROOT:[000000]MAVEN$CASE.COM
$ say = "write sys$output"
$ say ""
$ say "    Post-installation tasks for Apache Maven"
$ say ""
$ say "    At system startup: to define MAVEN$ROOT at every boot, add this"
$ say "    line to SYS$MANAGER:SYSTARTUP_VMS.COM:"
$ say "    $ @SYS$STARTUP:MAVEN$STARTUP.COM"
$ say "    For each user: to define the MVN command, add this line to"
$ say "    LOGIN.COM or SYS$MANAGER:SYLOGIN.COM:"
$ say "    $ @MAVEN$ROOT:[000000]MAVEN$SETUP.COM"
$ say "    Maven needs VSI OpenJDK 8 (SYS$STARTUP:OPENJDK$SETUP.COM)."
$ say ""
$ say "    PRODUCT REMOVE MAVEN removes the product and deassigns MAVEN$ROOT."
$ say ""
$ exit 1
