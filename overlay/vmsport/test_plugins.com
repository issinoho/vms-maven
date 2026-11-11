$! TEST_PLUGINS.COM - plugins that run programs and plugins that write many files
$! (docs/PLAN.md Phase 2), with the tree this [.VMSPORT] is in (run BUILD.COM first).
$! Uses [.VMSPORT.TESTS.PLUGINS] copied into [.VMSPORT.PLWORK]; the shared local
$! repository is [-.REPO] next to the tree.
$!   exec:java   in Maven's JVM: writes 300 files
$!   exec:exec   a new JVM in target/, with the project classpath and a mixed-case argument
$!   antrun      mkdir, echo, copy (dotted names), delete, and <java fork="true">
$!   javadoc:jar the javadoc tool, started through /bin/sh (MVNSH.EXE)
$!   assembly    zip and tar.gz of the generated files, dotted names and dependencies
$! Prints PASS/FAIL/KNOWN per test and "PLUGINS: <n> passed, <m> failed, <k> known".
$ set noon
$ on control_y then goto done
$! Without privileges (NOTES N17).
$ oldprv = f$setprv("NOALL,NETMBX,TMPMBX")
$ set process/parse_style=extended
$ proc = f$environment("procedure")
$ port = f$parse(proc,,,"device") + f$parse(proc,,,"directory")
$ home = f$edit(port,"upcase") - ".VMSPORT]" + "]"
$ work = home - "]" + ".VMSPORT.PLWORK]"
$ olddef = f$environment("default")
$ if f$type(java) .eqs. "" then @SYS$STARTUP:OPENJDK$SETUP.COM
$ mvn = "$" + home - "]" + ".BIN]MVN.EXE"
$ passed = 0
$ failed = 0
$ known = 0
$ write sys$output "PLUGINS: ''home' on ''f$getsyi("arch_name")' ''f$getsyi("version")'"
$! [-.REPO]: the work directory above the tree.
$ hd = f$parse(home,,,"directory") - "]"
$ n = 0
$ cnt_loop:
$ if f$element(n,".",hd) .eqs. "." then goto cnt_done
$ n = n + 1
$ goto cnt_loop
$ cnt_done:
$ repo = f$element(0,".",hd)
$ i = 1
$ up_loop:
$ if i .ge. n - 1 then goto up_done
$ repo = repo + "." + f$element(i,".",hd)
$ i = i + 1
$ goto up_loop
$ up_done:
$ repo = f$parse(home,,,"device") + repo + ".REPO]"
$ if f$parse(repo + "X.X") .eqs. "" then create/directory/version_limit=1 'repo'
$ spec = repo
$ gosub to_unix
$ urepo = uspec
$ r = "-Dmaven.repo.local=''urepo'"
$!
$! A fresh work directory with the project.
$ if f$search(home - "]" + ".VMSPORT]PLWORK.DIR") .nes. ""
$ then
$   wtree = work - "]" + "...]"
$   set file/protection=(o:rwed) 'wtree'*.dir;*
$   i = 0
$ del_loop:
$   define/user sys$output nl:
$   define/user sys$error nl:
$   delete/nolog 'wtree'*.*;*
$   i = i + 1
$   if i .lt. 15 .and. f$search(work - "]" + "...]*.*") .nes. "" then goto del_loop
$ endif
$ bsrc = home - "]" + ".VMSPORT.TESTS.PLUGINS...]*.*;*"
$ bdst = work - "]" + ".plugins...]*.*;*"
$ backup/nolog 'bsrc' 'bdst'
$ set default 'work'
$ tgt = work - "]" + ".plugins.target"
$!
$! 1. exec:java, in Maven's JVM: 300 files in target/gen.
$ t = "exec:java writes 300 files"
$ set default [.plugins]
$ pipe mvn -B -ntp "''r'" compile exec:java@gen > 'work'pl1.out
$ st = $status
$ set default 'work'
$ cnt = 0
$ g_loop:
$ gf = f$search(tgt + ".gen]f*.txt;*", 1)
$ if gf .eqs. "" then goto g_done
$ cnt = cnt + 1
$ goto g_loop
$ g_done:
$ write sys$output "     files in target/gen: ''cnt'"
$ fil = "pl1.out"
$ want = "Tool: generated 300 files"
$ gosub has_in
$ if st .and. found .and. cnt .eq. 300 then gosub pass
$ if .not. (st .and. found .and. cnt .eq. 300) then gosub fail
$!
$! 2. exec:exec: a new JVM in target/, its classpath, an argument with a space and capitals.
$ t = "exec:exec runs a new JVM"
$ set default [.plugins]
$ pipe mvn -B -ntp "''r'" exec:exec@fork > 'work'pl2.out
$ st = $status
$ set default 'work'
$ fil = "pl2.out"
$ want = "Tool: forked|MixedCase Arg in target, Lang3 ok"
$ gosub has_in
$ if st .and. found then gosub pass
$ if st .and. found then goto exec_done
$! commons-exec (1.4.0-1.6.0) writes a DCL procedure on OpenVMS that DCL cannot
$! parse (NOTES N20): known, and reported as such until it is fixed upstream.
$ want = "%DCL-E-PARSEFAIL, error parsing DCL$PATH:TRUE"
$ gosub has_in
$ if found then known = known + 1
$ if found then write sys$output "KNOWN: ''t' (commons-exec's VmsCommandLauncher, NOTES N20)"
$ if .not. found then gosub fail
$ exec_done:
$!
$! 3. antrun: file tasks (dotted names) and <java fork="true">.
$ t = "antrun: mkdir, echo, copy, delete, forked java"
$ set default [.plugins]
$ pipe mvn -B -ntp "''r'" antrun:run@ant > 'work'pl3.out
$ st = $status
$ set default 'work'
$ fil = "pl3.out"
$ want = "Lang3 ok"
$ gosub has_in
$ ok1 = st .and. found
$ want = "Tool: ant|MixedCase Arg in "
$ gosub has_in
$ whole = found
$! Ant's VmsCommandLauncher writes the arguments unquoted into a DCL procedure, so one
$! with a space arrives as two (NOTES N20): known until fixed upstream.
$ want = "Tool: ant|MixedCase|Arg in "
$ gosub has_in
$ split = found
$ ok1 = ok1 .and. (whole .or. split)
$ ok2 = f$search(tgt + ".ant.copy.names]multi^.dot^.name.txt") .nes. "" .and. -
        f$search(tgt + ".ant.copy.names.dir^.with^.dots]inner.txt") .nes. "" .and. -
        f$search(tgt + ".ant]echo.txt;*") .eqs. ""
$ if .not. ok2 then write sys$output "     antrun's files are not as expected"
$ if ok1 .and. ok2 .and. whole then gosub pass
$ if ok1 .and. ok2 .and. .not. whole then known = known + 1
$ if ok1 .and. ok2 .and. .not. whole then -
     write sys$output "KNOWN: ''t' (an argument with a space is split: Ant's VmsCommandLauncher, NOTES N20)"
$ if .not. (ok1 .and. ok2) then gosub fail
$!
$! 4. javadoc:jar: the javadoc tool (through /bin/sh), many HTML files, a jar of them.
$ t = "javadoc:jar"
$ set default [.plugins]
$ pipe mvn -B -ntp "''r'" javadoc:jar > 'work'pl4.out
$ st = $status
$ set default 'work'
$ ok1 = st .and. f$search(tgt + "]plugins-1^.0-javadoc.jar") .nes. ""
$ if ok1 then pipe jar tf plugins/target/plugins-1.0-javadoc.jar > pl4.lis
$ fil = "pl4.lis"
$ want = "com/example/plugins/Tool.html"
$ gosub has_in
$ ok1 = ok1 .and. found
$ fil = "pl4.out"
$ if ok1 then gosub pass
$ if .not. ok1 then gosub fail
$!
$! 5. assembly: zip and tar.gz with the generated files, dotted names and jars.
$ t = "assembly: zip and tar.gz"
$ set default [.plugins]
$ pipe mvn -B -ntp "''r'" package assembly:single@dist > 'work'pl5.out
$ st = $status
$ set default 'work'
$ zip = tgt + "]plugins-1^.0-dist.zip"
$ tgz = tgt + "]plugins-1^.0-dist.tar.gz"
$ ok1 = st .and. f$search(zip) .nes. "" .and. f$search(tgz) .nes. ""
$ if ok1 then ok1 = f$file(tgz,"EOF") .gt. 0
$ if ok1 then pipe jar tf plugins/target/plugins-1.0-dist.zip > pl5.lis
$ fil = "pl5.lis"
$ want = "plugins-1.0/gen/f299.txt"
$ gosub has_in
$ ok1 = ok1 .and. found
$ want = "plugins-1.0/names/multi.dot.name.txt"
$ gosub has_in
$ ok1 = ok1 .and. found
$ want = "plugins-1.0/names/dir.with.dots/inner.txt"
$ gosub has_in
$ ok1 = ok1 .and. found
$ want = "plugins-1.0/lib/commons-lang3-3.17.0.jar"
$ gosub has_in
$ ok1 = ok1 .and. found
$ want = "plugins-1.0/lib/plugins-1.0.jar"
$ gosub has_in
$ ok1 = ok1 .and. found
$ fil = "pl5.out"
$ if ok1 then gosub pass
$ if .not. ok1 then gosub fail
$!
$ done:
$ set default 'olddef'
$ write sys$output "PLUGINS: ''passed' passed, ''failed' failed, ''known' known"
$ oldprv = f$setprv(oldprv)
$ exit
$!
$ pass:
$   passed = passed + 1
$   write sys$output "PASS: ''t'"
$   return
$ fail:
$   failed = failed + 1
$   write sys$output "FAIL: ''t' (status ''st')"
$   if f$type(fil) .nes. "" then if f$search(fil) .nes. "" then type 'fil'
$   return
$!
$ has_in:
$   found = 0
$   if f$search(fil) .eqs. "" then return
$   define/user sys$output nl:
$   search 'fil' "''want'"
$   if $severity .eq. 1 then found = 1
$   return
$!
$! to_unix: SPEC (DEV:[A.B]) -> USPEC (/DEV/A/B), with ODS-5 "^." as ".".
$ to_unix:
$   d = f$parse(spec,,,"device") - ":"
$   p = f$parse(spec,,,"directory") - "[" - "]" - "<" - ">"
$   p = p + "]"
$   u = ""
$ tu_loop:
$   c = f$extract(0,1,p)
$   p = f$extract(1,999,p)
$   if c .eqs. "]" then goto tu_end
$   if c .eqs. "^"
$   then
$     u = u + f$extract(0,1,p)
$     p = f$extract(1,999,p)
$     goto tu_loop
$   endif
$   if c .eqs. "." then c = "/"
$   u = u + c
$   goto tu_loop
$ tu_end:
$   uspec = "/" + d + "/" + u
$   return
