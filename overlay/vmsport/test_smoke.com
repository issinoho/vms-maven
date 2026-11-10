$! TEST_SMOKE.COM - smoke test of the launcher and the patched Maven in the tree this
$! [.VMSPORT] is in (run BUILD.COM first). Builds a copy of [.VMSPORT.TESTS.HELLO] in
$! [.VMSPORT.WORK]; the local repository is [-.REPO] next to the tree, so only the
$! first run downloads Maven's default plugins from Maven Central.
$! Prints PASS/FAIL per test and "SMOKE: <n> passed, <m> failed".
$ set noon
$ on control_y then goto done
$! Without privileges: the account may hold SYSPRV, and a Maven run once deleted the
$! JDK's tools.jar (NOTES N17). A stray delete must fail, not take a system file.
$ oldprv = f$setprv("NOALL,NETMBX,TMPMBX")
$ set process/parse_style=extended
$ proc = f$environment("procedure")
$ port = f$parse(proc,,,"device") + f$parse(proc,,,"directory")
$ home = f$edit(port,"upcase") - ".VMSPORT]" + "]"
$ work = home - "]" + ".VMSPORT.WORK]"
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
$ olddef = f$environment("default")
$ if f$type(java) .eqs. "" then @SYS$STARTUP:OPENJDK$SETUP.COM
$ mvn = "$" + home - "]" + ".BIN]MVN.EXE"
$ passed = 0
$ failed = 0
$ write sys$output "SMOKE: ''home' on ''f$getsyi("arch_name")' ''f$getsyi("version")'"
$!
$ spec = home
$ gosub to_unix
$ uhome = uspec
$ if f$parse(repo + "X.X") .eqs. "" then create/directory/version_limit=1 'repo'
$ spec = repo
$ gosub to_unix
$ urepo = uspec
$ r = "-Dmaven.repo.local=''urepo'"
$!
$! A fresh copy of the test project.
$ if f$search(home - "]" + ".VMSPORT]WORK.DIR") .nes. ""
$ then
$   wtree = work - "]" + "...]"
$   set file/protection=(o:rwed) 'wtree'*.dir;*
$   i = 0
$ del_loop:
$!  Directories go only once empty: hide the warnings of the early passes.
$   define/user sys$output nl:
$   define/user sys$error nl:
$   delete/nolog 'wtree'*.*;*
$   i = i + 1
$   if i .lt. 12 .and. f$search(work - "]" + "...]*.*") .nes. "" then goto del_loop
$ endif
$ bsrc = home - "]" + ".VMSPORT.TESTS...]*.*;*"
$ bdst = work - "]" + "...]*.*;*"
$ backup/nolog 'bsrc' 'bdst'
$ set default 'work'
$ spec = work - "]" + ".HELLO]"
$ gosub to_unix
$ uhello = uspec
$!
$! 1. mvn -v: the launcher finds Java and the Maven home.
$ t = "mvn -v"
$ pipe mvn -v > t1.out
$ st = $status
$ want = "Apache Maven 3.9.16"
$ gosub has
$ ok1 = found
$! The launcher reports the home as the image's physical path.
$ want = "Maven home: /"
$ gosub has
$ if ok1 .and. found .and. st then gosub pass
$ if .not. (ok1 .and. found .and. st) then gosub fail
$!
$! 2. Build the project: plugins from Central, javac, JUnit (in-process), jar.
$ set default [.hello]
$! surefire forks its test JVM through /bin/sh = MVNSH.EXE (the launcher's
$! JAVA$EXEC_MAPPING), with patch 0002's small argLine.
$ want = "Running com.example.HelloTest"
$ t = "mvn package (download, compile, forked JUnit test, jar)"
$ pipe mvn -B -ntp "''r'" package > [-]t2.out
$ st = $status
$ set default [-]
$ want = "Tests run: 1, Failures: 0, Errors: 0"
$ gosub has_t2
$ if st .and. found .and. f$search("[.hello.target]hello-1^.0-SNAPSHOT.jar") .nes. "" then gosub pass
$ if .not. (st .and. found .and. f$search("[.hello.target]hello-1^.0-SNAPSHOT.jar") .nes. "") then gosub fail
$!
$! 3. The jar it built runs.
$ t = "the built jar runs"
$ pipe java "-cp" "''uhello'/target/hello-1.0-SNAPSHOT.jar" "com.example.Hello" > t3.out
$ want = "Hello from Maven on OpenVMS"
$ gosub has
$ if found then gosub pass
$ if .not. found then gosub fail
$!
$! 4. Arguments keep their case: -DskipTests reaches Maven as typed.
$ set default [.hello]
$ t = "-DskipTests keeps its case"
$ pipe mvn -B -ntp "''r'" -DskipTests package > [-]t4.out
$ st = $status
$ set default [-]
$ want = "Tests are skipped."
$ fil = "t4.out"
$ gosub has_in
$ if st .and. found then gosub pass
$ if .not. (st .and. found) then gosub fail
$!
$! 5. A failed build gives an error status, as Java's exit(1) does.
$ set default [.hello]
$ t = "a failed build returns an error status"
$ pipe mvn -B -ntp "''r'" nosuchphase > [-]t5.out
$ st = $status
$ set default [-]
$ want = "Unknown lifecycle phase"
$ fil = "t5.out"
$ gosub has_in
$ if found .and. (st .and. 7) .eq. 2 then gosub pass
$ if .not. (found .and. (st .and. 7) .eq. 2) then gosub fail
$!
$! 6. From a subdirectory: the base directory is the one with .mvn, and
$!    .mvn/jvm.config and MAVEN_OPTS reach the JVM.
$ t = ".mvn base directory, jvm.config, MAVEN_OPTS"
$ create/directory [.hello.^.mvn]
$ open/write cfg [.hello.^.mvn]jvm.config
$ write cfg "-Dvms.smoke.jvm=cfg"
$ write cfg "-Xmx512m"
$ close cfg
$ set default [.hello.src.main]
$ maven_opts = "-Dvms.smoke=opts"
$ maven_vms_trace = "1"
$ pipe mvn -v 2> 'work't6.err > 'work't6.out
$ st = $status
$ delete/symbol/local maven_opts
$ delete/symbol/local maven_vms_trace
$ set default 'work'
$ fil = "t6.err"
$! (SEARCH strings cannot hold quotes: look for each part on its own.)
$ want = "maven.multiModuleProjectDirectory=''uhello'"
$ gosub has_in
$ ok1 = found
$ want = "-Dvms.smoke.jvm=cfg"
$ gosub has_in
$ ok1 = ok1 .and. found
$ want = "-Xmx512m"
$ gosub has_in
$ ok1 = ok1 .and. found
$ want = "-Dvms.smoke=opts"
$ gosub has_in
$ if st .and. ok1 .and. found then gosub pass
$ if .not. (st .and. ok1 .and. found) then gosub fail
$ delete/nolog [.hello.^.mvn]jvm.config;*
$ set file/protection=(o:rwed) [.hello]^.mvn.dir
$ delete/nolog [.hello]^.mvn.dir;*
$!
$! 7. -f names the project from another directory.
$ t = "-f hello/pom.xml from the directory above"
$ pipe mvn -B -ntp -q "''r'" -f hello/pom.xml validate > t7.out
$ st = $status
$ if st then gosub pass
$ if .not. st then gosub fail
$!
$! 8. The TRADITIONAL parse style lower-cases -DskipTests; the launcher says why it failed.
$ t = "TRADITIONAL parse style note"
$ set process/parse_style=traditional
$ set default [.hello]
$ pipe mvn -B -DskipTests -X nosuchphase 2> 'work't8.err > 'work't8.out
$ st = $status
$ set process/parse_style=extended
$ set default 'work'
$ fil = "t8.err"
$ want = "TRADITIONAL parse style"
$ gosub has_in
$ if found .and. .not. st then gosub pass
$ if .not. (found .and. .not. st) then gosub fail
$!
$ done:
$ set default 'olddef'
$ write sys$output "SMOKE: ''passed' passed, ''failed' failed"
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
$! has: is WANT in T<n>.OUT for the current test?  (has_t2: in t2.out)
$ has:
$   fil = "t" + f$string(passed + failed + 1) + ".out"
$   goto has_in
$ has_t2:
$   fil = "t2.out"
$ has_in:
$   found = 0
$   if f$search(fil) .eqs. "" then return
$   search/nooutput 'fil' "''want'"
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
