$! VMS_INSTALLCHECK.COM <tree-dir-name> <INSTALL|SMOKE|REMOVE> - install the MAVEN
$! kit and verify it, run the smoke test against the installed MVN, then remove it.
$! INSTALL and REMOVE change the system (PCSI database, SYS$COMMON:[MAVEN],
$! SYS$STARTUP:MAVEN$STARTUP.COM, the system logical MAVEN$ROOT); REMOVE leaves it
$! as it was.  tools/installcheck.sh runs the three steps in turn.
$ set noon
$ set process/parse_style=extended
$ arch = f$edit(f$getsyi("ARCH_NAME"), "UPCASE")
$ base = "I64VMS"
$ if arch .eqs. "X86_64" then base = "X86VMS"
$! A batch job starts in SYS$LOGIN: take the tree from this procedure's directory.
$ proc = f$environment("PROCEDURE")
$ tree = f$parse(proc,,,"DEVICE") + f$parse(proc,,,"DIRECTORY") - "]" + "." + p1 + "]"
$ step = f$edit(p2, "UPCASE")
$ if step .eqs. "SMOKE" then goto smoke
$ if step .eqs. "REMOVE" then goto remove
$!
$ kitdir = tree - "]" + ".KIT_''arch']"
$ write sys$output "=== INSTALL from ", kitdir
$ t0 = f$time()
$ product install MAVEN /producer=ISSINOHO /base_system='base' /source='kitdir' /options=noconfirm
$ write sys$output "=== install status ", $status, " (", t0, " - ", f$time(), ")"
$ product show product MAVEN /producer=ISSINOHO
$ write sys$output "=== VERIFY"
$ write sys$output "startup procedure: [", f$search("SYS$STARTUP:MAVEN$STARTUP.COM"), "]"
$ write sys$output "MAVEN$ROOT: [", f$trnlnm("MAVEN$ROOT"), "]"
$ @MAVEN$ROOT:[000000]MAVEN$SETUP.COM
$ write sys$output "setup status: ", $status
$ show symbol mvn
$! The files have their real names again (MAVEN$CASE.COM): no jar is upper case.
$ directory/noheading/notrailing MAVEN$ROOT:[000000]*.*,MAVEN$ROOT:[BIN]*.*,MAVEN$ROOT:[BOOT]*.*
$ directory/noheading/notrailing/protection/owner MAVEN$ROOT:[BIN]MVN.EXE,MAVEN$ROOT:[LIB]maven-core*.jar
$ njar = 0
$ nupper = 0
$count:
$ jf = f$search("MAVEN$ROOT:[LIB]*.jar;", 1)
$ if jf .eqs. "" then goto counted
$ njar = njar + 1
$ jn = f$parse(jf,,,"NAME") + f$parse(jf,,,"TYPE")
$ if jn .eqs. f$edit(jn, "UPCASE") then nupper = nupper + 1
$ goto count
$counted:
$ write sys$output "lib jars: ''njar', upper case: ''nupper'"
$ write sys$output "=== MVN -v"
$ pipe mvn -v
$ write sys$output "mvn -v status: ", $status
$ delete/symbol/global mvn
$ exit 1
$!
$smoke:
$ write sys$output "=== SMOKE TEST on the installed MVN"
$ smoke = tree - "]" + ".VMSPORT]TEST_SMOKE.COM"
$ @'smoke' MAVEN$ROOT:[BIN]MVN.EXE
$ exit 1
$!
$remove:
$ write sys$output "=== REMOVE"
$ product remove MAVEN /producer=ISSINOHO /options=noconfirm
$ write sys$output "=== remove status ", $status
$ write sys$output "MAVEN$ROOT after removal: [", f$trnlnm("MAVEN$ROOT"), "]"
$ write sys$output "files after removal: [", f$search("SYS$COMMON:[MAVEN...]*.*"), "]"
$ write sys$output "directory after removal: [", f$search("SYS$COMMON:[000000]MAVEN.DIR"), "]"
$ write sys$output "startup after removal: [", f$search("SYS$STARTUP:MAVEN$STARTUP.COM"), "]"
$ product show product MAVEN /producer=ISSINOHO
$ exit 1
