$! TEST_CONFIG.COM - settings.xml, toolchains.xml and the default local repository
$! (docs/PLAN.md Phase 2), with the tree this [.VMSPORT] is in (run BUILD.COM first).
$! Uses [.VMSPORT.TESTS.CONFIG] copied into [.VMSPORT.CFWORK], with a test home
$! [.VMSPORT.CFWORK.HOME] given to Java as user.home (in MAVEN_OPTS), so the account's
$! own SYS$LOGIN:[.m2] is not touched. The shared local repository is [-.REPO].
$!   1. the default local repository, <user.home>/.m2/repository, made by MVN.EXE
$!      with a version limit of 1
$!   2. ~/.m2/settings.xml: a profile's property
$!   3. conf/settings.xml: its openvms profile is active, with the user's
$!   4. -s <file> in place of the user settings
$!   5. ~/.m2/toolchains.xml: a JDK toolchain whose javac the compiler finds
$!      (JAVAC.EXE: patch 0004)
$! Prints PASS/FAIL per test and "CONFIG: <n> passed, <m> failed".
$ set noon
$ on control_y then goto done
$! Without privileges (NOTES N17).
$ oldprv = f$setprv("NOALL,NETMBX,TMPMBX")
$ set process/parse_style=extended
$ proc = f$environment("procedure")
$ port = f$parse(proc,,,"device") + f$parse(proc,,,"directory")
$ home = f$edit(port,"upcase") - ".VMSPORT]" + "]"
$ work = home - "]" + ".VMSPORT.CFWORK]"
$ olddef = f$environment("default")
$ if f$type(javac) .eqs. "" then @SYS$STARTUP:OPENJDK$SETUP.COM
$ mvn = "$" + home - "]" + ".BIN]MVN.EXE"
$ passed = 0
$ failed = 0
$ had_opts = f$type(maven_opts) .nes. ""
$ if had_opts then old_opts = maven_opts
$ write sys$output "CONFIG: ''home' on ''f$getsyi("arch_name")' ''f$getsyi("version")'"
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
$ r = "-Dmaven.repo.local=''uspec'"
$!
$! A fresh work directory with the project and the test home.
$ if f$search(home - "]" + ".VMSPORT]CFWORK.DIR") .nes. ""
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
$ bsrc = home - "]" + ".VMSPORT.TESTS.CONFIG...]*.*;*"
$ bdst = work - "]" + ".config...]*.*;*"
$ backup/nolog 'bsrc' 'bdst'
$ uhome = work - "]" + ".HOME]"
$ m2 = work - "]" + ".HOME.^.m2]"
$ create/directory 'm2'
$ hm2 = work - "]" + ".config.home-m2]"
$ copy/nolog 'hm2'settings.xml 'm2'settings.xml
$ spec = uhome
$ gosub to_unix
$ uh = uspec
$! The JDK: the directory above JAVAC.EXE's [.BIN].
$ jc = javac - "$"
$! SYNTAX_ONLY: without privileges [SYS0] cannot be looked into, and F$PARSE gives "".
$ jdk = f$parse(jc,,,"device","syntax_only") + -
        (f$parse(jc,,,"directory","syntax_only") - ".BIN]") + "]"
$ spec = jdk
$ gosub to_unix
$ ujdk = uspec
$ write sys$output "     user.home ''uh', JDK ''ujdk'"
$ open/write tc 'm2'toolchains.xml
$ write tc "<?xml version=""1.0"" encoding=""UTF-8""?>"
$ write tc "<toolchains>"
$ write tc "  <toolchain>"
$ write tc "    <type>jdk</type>"
$ write tc "    <provides><version>1.8</version></provides>"
$ write tc "    <configuration><jdkHome>''ujdk'</jdkHome></configuration>"
$ write tc "  </toolchain>"
$ write tc "</toolchains>"
$ close tc
$! user.home for the JVM: Maven reads the toolchains path from it at start-up.
$ maven_opts = "-Duser.home=''uh'"
$ set default 'work'
$!
$! 1. The default local repository: MVN.EXE makes it, with a version limit of 1.
$ t = "default local repository in user.home"
$ set default [.config]
$ pipe mvn -B -ntp -X -N validate > 'work'cf1.out
$ st = $status
$ set default 'work'
$ fil = "cf1.out"
$ want = "Using local repository at ''uh'/.m2/repository"
$ gosub has_in
$ rdir = work - "]" + ".HOME.^.m2.repository]"
$ ok = st .and. found .and. f$parse(rdir + "X.X") .nes. ""
$ if ok
$ then
$   create 'rdir'vl.tmp
$   create 'rdir'vl.tmp
$   nv = 0
$ vl_loop:
$   vf = f$search(rdir + "vl.tmp;*", 2)
$   if vf .eqs. "" then goto vl_done
$   nv = nv + 1
$   goto vl_loop
$ vl_done:
$   write sys$output "     versions of a file written twice: ''nv'"
$   ok = nv .eq. 1
$ endif
$ if ok then gosub pass
$ if .not. ok then gosub fail
$!
$! 2. ~/.m2/settings.xml: its active profile's property.
$ t = "user settings.xml"
$ set default [.config]
$ pipe mvn -B -ntp "''r'" help:evaluate "-Dexpression=cfg.user" -q -DforceStdout > 'work'cf2.out
$ st = $status
$ set default 'work'
$ fil = "cf2.out"
$ want = "from-user-settings"
$ gosub has_in
$ if st .and. found then gosub pass
$ if .not. (st .and. found) then gosub fail
$!
$! 3. conf/settings.xml: its openvms profile, with the user's.
$ t = "global conf/settings.xml"
$ set default [.config]
$ pipe mvn -B -ntp "''r'" help:active-profiles > 'work'cf3.out
$ st = $status
$ set default 'work'
$ fil = "cf3.out"
$ want = " - openvms (source: external)"
$ gosub has_in
$ ok = st .and. found
$ want = " - cfgtest (source: external)"
$ gosub has_in
$ ok = ok .and. found
$ if ok then gosub pass
$ if .not. ok then gosub fail
$!
$! 4. -s FILE replaces the user settings.
$ t = "-s settings file"
$ spec = work - "]" + ".config]"
$ gosub to_unix
$ alt = uspec + "/alt-settings.xml"
$ set default [.config]
$ pipe mvn -B -ntp "''r'" -s "''alt'" help:evaluate "-Dexpression=cfg.user" -q -DforceStdout > 'work'cf4.out
$ st = $status
$ set default 'work'
$ fil = "cf4.out"
$ want = "from-s-option"
$ gosub has_in
$ if st .and. found then gosub pass
$ if .not. (st .and. found) then gosub fail
$!
$! 5. ~/.m2/toolchains.xml: the compiler uses the toolchain's JAVAC.EXE (patch 0004);
$!    without it, "Unable to autodetect 'javac' path" and the bare name.
$ t = "user toolchains.xml: JDK toolchain javac"
$ set default [.config]
$ pipe mvn -B -ntp "''r'" -Ptoolchain clean compile > 'work'cf5.out
$ st = $status
$ set default 'work'
$ fil = "cf5.out"
$ want = "Found matching toolchain for type jdk: JDK[''ujdk']"
$ gosub has_in
$ ok = st .and. found
$ want = "Unable to autodetect 'javac' path"
$ gosub has_in
$ if found then write sys$output "     the toolchain's javac was not found"
$ ok = ok .and. .not. found
$ ok = ok .and. f$search(work - "]" + ".config.target.classes.com.example.config]Config.class") .nes. ""
$ if ok then gosub pass
$ if .not. ok then gosub fail
$!
$ done:
$ set default 'olddef'
$ if had_opts then maven_opts = old_opts
$ if .not. had_opts then delete/symbol/local maven_opts
$ write sys$output "CONFIG: ''passed' passed, ''failed' failed"
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
$   d = f$parse(spec,,,"device","syntax_only") - ":"
$   p = f$parse(spec,,,"directory","syntax_only") - "[" - "]" - "<" - ">"
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
