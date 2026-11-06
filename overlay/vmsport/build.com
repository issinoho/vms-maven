$! BUILD.COM [ALL|CLEAN] - build the VMS parts of the Maven tree this [.VMSPORT] is in:
$!
$!   [.BIN]MVN.EXE   the launcher (mvn.c, vms_crtl_init.c)
$!   [.LIB]*.JAR     the jars listed in PATCHED.LIS, with the patched classes
$!                   compiled from [.VMSPORT.SRC.<artifact>] put back in;
$!                   the upstream jars are kept in [.VMSPORT.PRISTINE]
$!
$! CLEAN puts the upstream jars back and deletes what ALL makes.
$! Java comes from SYS$STARTUP:OPENJDK$SETUP.COM when JAVAC is not defined.
$ set noon
$ on control_y then goto done
$ target = f$edit(p1,"upcase,trim")
$ if target .eqs. "" then target = "ALL"
$ proc = f$environment("procedure")
$ port = f$parse(proc,,,"device") + f$parse(proc,,,"directory")
$! ODS-5 keeps the case the directory was made with: compare in upper case.
$ home = f$edit(port,"upcase") - ".VMSPORT]" + "]"
$ olddef = f$environment("default")
$ set default 'home'
$ write sys$output "BUILD: ''target' in ''home' on ''f$getsyi("arch_name")' ''f$getsyi("version")'"
$ show time
$ errors = 0
$!
$! ---- CLEAN -------------------------------------------------------------------
$ if target .eqs. "CLEAN"
$ then
$   if f$search("[.vmsport.pristine]*.jar") .nes. "" then -
       copy/nolog [.vmsport.pristine]*.jar;0 [.lib]*.*
$   purge/nolog [.lib]*.jar
$   if f$search("[.bin]mvn.exe") .nes. "" then delete/nolog [.bin]mvn.exe;*
$   if f$search("[.vmsport.obj]*.*") .nes. "" then delete/nolog [.vmsport.obj]*.*;*
$   if f$search("[.vmsport.classes...]*.class") .nes. "" then -
       delete/nolog [.vmsport.classes...]*.class;*
$   goto done
$ endif
$!
$! ---- the launcher ------------------------------------------------------------
$ if f$search("[.vmsport]obj.dir") .eqs. "" then create/directory [.vmsport.obj]
$ ccq = "/names=(as_is,shortened)/warnings=(disable=(emptyfile))/object=[.vmsport.obj]"
$ cc'ccq' [.vmsport]mvn.c
$ if .not. $status then errors = errors + 1
$ cc'ccq' [.vmsport]vms_crtl_init.c
$ if .not. $status then errors = errors + 1
$ if errors .gt. 0
$ then
$   write sys$output "%BUILD-E-CC, the launcher did not compile"
$   goto done
$ endif
$ link/executable=[.bin]mvn.exe/notraceback [.vmsport.obj]mvn.obj,vms_crtl_init.obj
$ if .not. $status
$ then
$   write sys$output "%BUILD-E-LINK, the launcher did not link"
$   errors = errors + 1
$   goto done
$ endif
$ purge/nolog [.bin]mvn.exe
$ write sys$output "BUILD: [.BIN]MVN.EXE"
$!
$! ---- the patched jars --------------------------------------------------------
$ if f$type(javac) .eqs. "" then @SYS$STARTUP:OPENJDK$SETUP.COM
$ if f$search("[.vmsport]pristine.dir") .eqs. "" then create/directory [.vmsport.pristine]
$ if f$search("[.vmsport]classes.dir") .eqs. "" then create/directory [.vmsport.classes]
$ open/read/error=nolist lis [.vmsport]patched.lis
$ cur = ""
$ files = ""
$ next_line:
$   read/end_of_file=last_line lis line
$   line = f$edit(line,"compress,trim")
$   if line .eqs. "" then goto next_line
$   a = f$element(0," ",line)
$   v = f$element(1," ",line)
$   f = f$element(2," ",line)
$   if a .nes. cur .and. cur .nes. "" then gosub patch_jar
$   cur = a
$   curv = v
$   files = files + " ""vmsport/src/''a'/''f'"""
$   goto next_line
$ last_line:
$ close lis
$ if cur .nes. "" then gosub patch_jar
$ goto done
$ nolist:
$ write sys$output "%BUILD-E-NOLIST, [.VMSPORT]PATCHED.LIS is missing (run tools/prepare.sh)"
$ errors = errors + 1
$ goto done
$!
$! patch_jar: compile FILES (all from artifact CUR, version CURV) against lib/,
$! then put the classes into a fresh copy of the upstream jar.
$ patch_jar:
$!  (Not "jar": that would replace the JAR command.)
$   jarname = "''cur'-''curv'.jar"
$!  The DCL form of the name: ODS-5 needs the dots before the last escaped.
$   vj = ""
$   i = 0
$ esc_loop:
$   e = f$element(i,".",curv)
$   if e .eqs. "." then goto esc_done
$   vj = vj + e
$   if f$element(i+1,".",curv) .nes. "." then vj = vj + "^."
$   i = i + 1
$   goto esc_loop
$ esc_done:
$   vjar = "''cur'-''vj'.jar"
$   if f$search("[.vmsport.pristine]''vjar'") .eqs. "" then -
       copy/nolog [.lib]'vjar' [.vmsport.pristine]'vjar'
$   if f$search("[.vmsport.classes]''cur'.dir") .eqs. "" then -
       create/directory [.vmsport.classes.'cur']
$   if f$search("[.vmsport.classes.''cur'...]*.class") .nes. "" then -
       delete/nolog [.vmsport.classes.'cur'...]*.class;*
$   write sys$output "BUILD: javac for ", jarname, ":", files
$   define/user sys$error sys$output
$   javac "-nowarn" "-encoding" "UTF-8" "-source" "8" "-target" "8" "-cp" "lib/*" -
          "-d" "vmsport/classes/''cur'" 'files'
$   if .not. $status
$   then
$     write sys$output "%BUILD-E-JAVAC, ''cur' did not compile"
$     errors = errors + 1
$     goto patch_end
$   endif
$   copy/nolog [.vmsport.pristine]'vjar' [.lib]'vjar'
$   purge/nolog [.lib]'vjar'
$   define/user sys$error sys$output
$   jar "uf" "lib/''jarname'" "-C" "vmsport/classes/''cur'" "."
$   if .not. $status
$   then
$     write sys$output "%BUILD-E-JAR, could not update lib/''jarname'"
$     errors = errors + 1
$     goto patch_end
$   endif
$   write sys$output "BUILD: lib/''jarname' patched"
$ patch_end:
$   files = ""
$   return
$!
$ done:
$ set default 'olddef'
$ show time
$ if errors .eq. 0 then write sys$output "BUILD: done"
$ if errors .ne. 0 then write sys$output "%BUILD-E-FAILED, ''errors' error(s)"
$ exit
