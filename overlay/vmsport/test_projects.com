$! TEST_PROJECTS.COM - Maven on a real project layout (docs/PLAN.md Phase 2), with the
$! tree this [.VMSPORT] is in (run BUILD.COM first). Uses [.VMSPORT.TESTS.MULTI] (a
$! reactor of two modules, commons-lang3, shade, sources) copied into [.VMSPORT.PWORK];
$! the shared local repository is [-.REPO] next to the tree, and the concurrency tests
$! use fresh ones in [.VMSPORT.PWORK].
$! Prints PASS/FAIL per test and "PROJECTS: <n> passed, <m> failed".
$ set noon
$ on control_y then goto done
$! Without privileges: the account may hold SYSPRV, and a Maven run once deleted the
$! JDK's tools.jar (NOTES N17). A stray delete must fail, not take a system file.
$ oldprv = f$setprv("NOALL,NETMBX,TMPMBX")
$ set process/parse_style=extended
$ proc = f$environment("procedure")
$ port = f$parse(proc,,,"device") + f$parse(proc,,,"directory")
$ home = f$edit(port,"upcase") - ".VMSPORT]" + "]"
$ work = home - "]" + ".VMSPORT.PWORK]"
$ olddef = f$environment("default")
$ if f$type(java) .eqs. "" then @SYS$STARTUP:OPENJDK$SETUP.COM
$ mvn = "$" + home - "]" + ".BIN]MVN.EXE"
$ passed = 0
$ failed = 0
$ write sys$output "PROJECTS: ''home' on ''f$getsyi("arch_name")' ''f$getsyi("version")'"
$!
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
$ if f$parse(repo + "X.X") .eqs. "" then create/directory 'repo'
$ spec = repo
$ gosub to_unix
$ urepo = uspec
$ r = "-Dmaven.repo.local=''urepo'"
$!
$! A fresh work directory with two copies of the project.
$ if f$search(home - "]" + ".VMSPORT]PWORK.DIR") .nes. ""
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
$ bsrc = home - "]" + ".VMSPORT.TESTS.MULTI...]*.*;*"
$ bdst = work - "]" + ".multi...]*.*;*"
$ backup/nolog 'bsrc' 'bdst'
$ bdst = work - "]" + ".multi2...]*.*;*"
$ backup/nolog 'bsrc' 'bdst'
$ set default 'work'
$ spec = work
$ gosub to_unix
$ uwork = uspec
$!
$! 1. Reactor build and install.
$ t = "reactor install (core, app; commons-lang3, shade, sources)"
$ set default [.multi]
$ pipe mvn -B -ntp "''r'" install > 'work'p1.out
$ st = $status
$ set default 'work'
$ fil = "p1.out"
$ want = "Reactor Summary"
$ gosub has_in
$ ok1 = found
$ want = "Tests run: 2, Failures: 0, Errors: 0"
$ gosub has_in
$ if st .and. ok1 .and. found then gosub pass
$ if .not. (st .and. ok1 .and. found) then gosub fail
$!
$! 2. The shaded jar runs (core + commons-lang3 inside, filtered resource).
$ t = "the shaded app jar runs"
$ pipe java "-jar" "''uwork'/multi/app/target/app-1.0.jar" "vms" > p2.out
$ fil = "p2.out"
$ want = "Hello, Vms, from a Maven reactor on OpenVMS (app 1.0)"
$ gosub has_in
$ if found then gosub pass
$ if .not. found then gosub fail
$!
$! 3. The artifacts are in the local repository.
$ t = "installed artifacts in the local repository"
$ g = repo - "]" + ".com.example.multi"
$ ok1 = f$search(g + ".core.1^.0]core-1^.0.jar") .nes. "" .and. -
        f$search(g + ".core.1^.0]core-1^.0-sources.jar") .nes. "" .and. -
        f$search(g + ".app.1^.0]app-1^.0.jar") .nes. "" .and. -
        f$search(g + ".multi.1^.0]multi-1^.0.pom") .nes. ""
$ st = ok1
$ if ok1 then gosub pass
$ if .not. ok1 then gosub fail
$!
$! 4. Installing again replaces the files: no pile of file versions.
$ t = "a second install leaves one version of each file"
$ set default [.multi]
$ pipe mvn -B -ntp -q "''r'" install > 'work'p4.out
$ st = $status
$ set default 'work'
$ cnt = 0
$ v_loop:
$ vf = f$search(g + ".core.1^.0]core-1^.0.jar;*", 4)
$ if vf .eqs. "" then goto v_done
$ cnt = cnt + 1
$ goto v_loop
$ v_done:
$ write sys$output "     versions of core-1.0.jar: ''cnt'"
$ if st .and. cnt .eq. 1 then gosub pass
$ if .not. (st .and. cnt .eq. 1) then gosub fail
$!
$! 5. Deploy to a file repository.
$ t = "deploy to a file:// repository"
$ create/directory [.deployrepo]
$ set default [.multi]
$ pipe mvn -B -ntp "''r'" -DskipTests "-DaltDeploymentRepository=vmstest::file://''uwork'/deployrepo" deploy > 'work'p5.out
$ st = $status
$ set default 'work'
$ d = work - "]" + ".deployrepo.com.example.multi"
$ ok1 = f$search(d + ".core.1^.0]core-1^.0.jar") .nes. "" .and. -
        f$search(d + ".core.1^.0]core-1^.0.jar.sha1") .nes. "" .and. -
        f$search(d + ".core]maven-metadata.xml") .nes. "" .and. -
        f$search(d + ".app.1^.0]app-1^.0-sources.jar") .nes. ""
$ fil = "p5.out"
$ if st .and. ok1 then gosub pass
$ if .not. (st .and. ok1) then gosub fail
$!
$! 6. clean deletes the target directories.
$ t = "clean removes target/"
$ set default [.multi]
$ pipe mvn -B -ntp -q "''r'" clean > 'work'p6.out
$ st = $status
$ set default 'work'
$ ok1 = f$search("[.multi.core]target.dir") .eqs. "" .and. f$search("[.multi.app]target.dir") .eqs. ""
$ fil = "p6.out"
$ if st .and. ok1 then gosub pass
$ if .not. (st .and. ok1) then gosub fail
$!
$! 7-8. Two Maven builds at once (two batch jobs, as two users would be: in one job
$!      they would share its pooled quotas), each with an empty shared repository to
$!      fill: the resolver's default (in-JVM) locking, then its file locks across
$!      processes. Needs SYS$BATCH's job limit to be 3 or more.
$ conc_mode = "default"
$ conc_opts = ""
$ gosub concurrent
$ conc_mode = "file-lock"
$ conc_opts = """-Daether.syncContext.named.factory=file-lock"" ""-Daether.syncContext.named.nameMapper=file-gav"""
$ gosub concurrent
$!
$ done:
$ set default 'olddef'
$ write sys$output "PROJECTS: ''passed' passed, ''failed' failed"
$ oldprv = f$setprv(oldprv)
$ exit
$!
$! concurrent: build multi and multi2 at the same time into a fresh repository.
$ concurrent:
$   t = "two builds at once, one empty repository (''conc_mode')"
$   cm = conc_mode - "-"
$   cr = work - "]" + ".repo_" + cm + "]"
$   create/directory 'cr'
$   spec = cr
$   gosub to_unix
$   ucr = uspec
$   k = 1
$ c_spawn:
$   pd = "multi"
$   if k .eq. 2 then pd = "multi2"
$   open/write c c'k'.com
$   write c "$ set noon"
$   write c "$ set process/privileges=(noall,netmbx,tmpmbx)"
$   write c "$ set process/parse_style=extended"
$   write c "$ @SYS$STARTUP:OPENJDK$SETUP.COM"
$   write c "$ mvn = ""''mvn'"""
$   pdir = work - "]" + ".''pd']"
$   write c "$ set default ''pdir'"
$!  (Built by concatenation: CONC_OPTS holds quotes.)
$   line = "$ mvn -B -ntp ""-Dmaven.repo.local=" + ucr + """ " + conc_opts + " install"
$   write c line
$   write c "$ st = $status"
$   write c "$ open/write d ''work'c''k'.done"
$   write c "$ write d st"
$   write c "$ close d"
$   close c
$   if f$search("c''k'.done") .nes. "" then delete/nolog c'k'.done;*
$   if f$search("c''k'.out") .nes. "" then delete/nolog c'k'.out;*
$   submit/noprint/log_file='work'c'k'.out 'work'c'k'.com
$   k = k + 1
$   if k .le. 2 then goto c_spawn
$   waited = 0
$ c_wait:
$   if f$search("c1.done") .nes. "" .and. f$search("c2.done") .nes. "" then goto c_both
$   wait 00:00:05
$   waited = waited + 5
$   if waited .lt. 2400 then goto c_wait
$   st = 0
$   fil = "c1.out"
$   gosub fail
$   return
$ c_both:
$   open/read d c1.done
$   read d s1
$   close d
$   open/read d c2.done
$   read d s2
$   close d
$   st = "''s1'/''s2'"
$   ok1 = s1 .and. s2
$   fil = "c1.out"
$   want = "Tests run: 2, Failures: 0, Errors: 0"
$   gosub has_in
$   ok1 = ok1 .and. found
$   fil = "c2.out"
$   gosub has_in
$   ok1 = ok1 .and. found
$   if ok1 then gosub pass
$   if .not. ok1
$   then
$     fil = "c1.out"
$     gosub fail
$     type c2.out
$   endif
$   return
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
