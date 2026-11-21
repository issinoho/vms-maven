#!/usr/bin/env python3
"""ttytest.py <node> - run MVN interactively on <node> and check what a terminal shows.

The batch suites (test.sh) run Maven with no terminal; this logs in to the node
over ssh in a pseudo-terminal (132x40), runs the built MVN.EXE from DCL, and
checks the screen (pyte), the raw output, DCL's status and the process's
subprocesses:
  version     mvn -v
  build       a build's output; no colour by default; success status
  colour      -Dstyle.color=always gives colour
  ctrl-c      CTRL/C during a build: back to DCL, Java exited 130 (as MVN.EXE
              reports it), Java gone
  ctrl-y      the same for CTRL/Y (MVN.EXE passes it to Java as SIGINT)
              $STATUS after either is shown, not checked (NOTES N24)
  ctrl-y-dcl  afterwards CTRL/Y interrupts DCL again
The project is a copy of [.VMSPORT.TESTS.HELLO] in <workdir>[.TTYWORK.HELLO]; the
local repository is <workdir>[.REPO], which test.sh's suites fill.

Needs pexpect and pyte on the host (tools/ttytest.sh finds a python that has them).
Output: out/tty-<node>.log; exit status 0 only if every check passes.
TTYTEST_TRACE=1 also defines MAVEN_VMS_TRACE on the node (the launcher then reports
the Java command, whether it took CTRL/Y, and Java's wait status) and writes the raw
terminal output to out/tty-<node>.raw.
"""
import os
import re
import sys
import time

import pexpect
import pyte

TOP = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROMPT = 'TTY> '
ROWS, COLS = 40, 132
SGR = re.compile(rb'\x1b\[[0-9;]*m')


def read_conf(node):
    for line in open(os.path.join(TOP, 'tools', 'nodes.conf')):
        f = line.split()
        if f and not f[0].startswith('#') and f[0] == node:
            return f
    sys.exit('ttytest: unknown node %s' % node)


def upstream():
    conf = {}
    for line in open(os.path.join(TOP, 'upstream.conf')):
        m = re.match(r'(\w+)=(.*)', line.strip())
        if m:
            conf[m.group(1)] = m.group(2).strip('"')
    return conf


class Session:
    def __init__(self, node):
        _, arch, host, port, user, workdir, _ = read_conf(node)
        self.workdir = workdir
        self.screen = pyte.Screen(COLS, ROWS)
        self.stream = pyte.ByteStream(self.screen)
        self.raw = b''          # output since the last mark()
        self.rawlog = None
        self.child = pexpect.spawn(
            'ssh', ['-tt', '-p', port, '-i',
                    os.path.expanduser(os.environ.get('VMS_SSH_KEY', '~/.ssh/vms_ed25519')),
                    '-o', 'BatchMode=yes', '%s@%s' % (user, host)],
            env=dict(os.environ, TERM='vt100'), dimensions=(ROWS, COLS), timeout=60)

    def pump(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            try:
                data = self.child.read_nonblocking(65536, timeout=0.2)
            except pexpect.TIMEOUT:
                continue
            except pexpect.EOF:
                return
            self.raw += data
            if self.rawlog:
                self.rawlog.write(data)
                self.rawlog.flush()
            self.stream.feed(data)

    def until(self, pred, seconds):
        end = time.time() + seconds
        while time.time() < end and not pred():
            self.pump(0.3)
        return pred()

    def mark(self):
        self.raw = b''
        self.screen.reset()

    def text(self):
        return self.raw.decode('latin-1')

    def prompted(self):
        """DCL's prompt is the last thing written."""
        return self.text().rstrip(' \x00').endswith(PROMPT.rstrip())

    def dcl(self, command, seconds=60):
        """Run a DCL command and wait for the prompt; the output is in self.raw."""
        self.mark()
        self.child.send(command + '\r')
        self.pump(0.3)
        return self.until(self.prompted, seconds)

    def symbol(self, expr):
        self.dcl('write sys$output "=[", %s, "]="' % expr)
        m = re.search(r'=\[(.*?)\]=', self.text().split('\n', 1)[-1])
        return m.group(1) if m else None

    def dump(self):
        return '\n'.join('%2d|%s' % (i, l.rstrip())
                         for i, l in enumerate(self.screen.display) if l.strip())


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    node = sys.argv[1]
    up = upstream()
    tree = (up['UPSTREAM_NAME'] + '-' + up['UPSTREAM_VERSION']).replace('.', '_').upper()
    os.makedirs(os.path.join(TOP, 'out'), exist_ok=True)
    log = open(os.path.join(TOP, 'out', 'tty-%s.log' % node), 'w')
    results = []

    def check(name, ok, s, detail=''):
        results.append(ok)
        line = '%s %s%s' % ('PASS' if ok else 'FAIL', name, (' (%s)' % detail) if detail else '')
        print(line, flush=True)
        log.write(line + '\n')
        if not ok:
            log.write(s.dump() + '\n')
        log.flush()

    s = Session(node)
    trace = bool(os.environ.get('TTYTEST_TRACE'))
    if trace:
        s.rawlog = open(os.path.join(TOP, 'out', 'tty-%s.raw' % node), 'wb')
    s.child.expect([r'::', r'\$ ', pexpect.TIMEOUT], timeout=60)
    s.pump(2)
    s.child.send('set prompt="%s"\r' % PROMPT)
    s.pump(2)
    work = s.workdir[:-1] + '.TTYWORK]'
    for cmd in ('set default %s' % s.workdir,
                'set terminal/page=%d/width=%d' % (ROWS, COLS),
                'set process/parse_style=extended',
                'if f$type(java) .eqs. "" then @SYS$STARTUP:OPENJDK$SETUP.COM',
                'mvn :== $%s.%s.BIN]MVN.EXE' % (s.workdir[:-1], tree),
                'if f$search("%sHELLO.DIR") .eqs. "" then backup [.%s.VMSPORT.TESTS.HELLO...]*.* [.TTYWORK.HELLO...]'
                % (work, tree),
                'set default [.TTYWORK.HELLO]'):
        s.dcl(cmd)
    if trace:
        s.dcl('define/nolog maven_vms_trace 1')
    # The shared repository [.REPO] is two levels up.
    repo = '"-Dmaven.repo.local=../../repo"'

    # mvn -v: a JVM start, but none of Maven's container.
    s.dcl('mvn -v', 300)
    check('version', 'Apache Maven ' + up['UPSTREAM_VERSION'] in s.text()
          and 'OS name: "openvms"' in s.text(), s)

    # A build: output as it comes, plain (jansi has no native library on
    # OpenVMS and Maven leaves colour off), and a success status.
    s.dcl('mvn %s validate' % repo, 600)
    plain = not SGR.search(s.raw)
    check('build', 'BUILD SUCCESS' in s.text() and plain, s,
          '' if plain else 'escape sequences in the output')
    check('build-status', s.symbol('$severity') == '1', s)

    # -Dstyle.color=always: Maven's colours, which a VT terminal shows.
    s.dcl('mvn %s "-Dstyle.color=always" validate' % repo, 600)
    coloured = any(c.fg != 'default' for row in s.screen.buffer.values() for c in row.values())
    check('colour', 'BUILD SUCCESS' in s.text() and coloured, s)

    # CTRL/C and CTRL/Y once the build is under way (after "Building hello",
    # in the plugins).  Java runs its shutdown hooks and exits 130, which
    # MVN.EXE reports under MAVEN_VMS_TRACE ("wait status %X00008200") and
    # turns into an error status (%X1035A412); Java is no longer there.
    # DCL also acts on the key once the image ends, so $STATUS at the prompt
    # is not reliable (NOTES N24): it is shown, not checked.
    if not trace:
        s.dcl('define/nolog maven_vms_trace 1')
    for name, key in (('ctrl-c', '\x03'), ('ctrl-y', '\x19')):
        s.mark()
        s.child.send('mvn %s clean package\r' % repo)
        started = s.until(lambda: 'Building hello' in s.text(), 600)
        s.pump(3)
        s.child.send(key)
        back = s.until(s.prompted, 60)
        stopped = 'BUILD SUCCESS' not in s.text()
        check(name, started and back and stopped, s,
              'not started' if not started else 'no prompt' if not back
              else 'ran to the end' if not stopped else '')
        m = re.search(r'Java ended, wait status (%X[0-9A-F]+)', s.text())
        check(name + '-java-130', bool(m) and m.group(1) == '%X00008200', s,
              'wait status %s' % (m.group(1) if m else 'not reported'))
        status = s.symbol('$status')
        line = 'INFO %s-status %s' % (name, status)
        print(line, flush=True)
        log.write(line + '\n')
        sub = s.symbol('f$getjpi("","PRCCNT")')
        check(name + '-java-gone', sub == '0', s, '%s subprocesses' % sub)
    if not trace:
        s.dcl('deassign maven_vms_trace')

    # DCL has CTRL/Y back: it interrupts a READ.
    s.mark()
    s.child.send('read sys$command x /prompt="type CTRL/Y: "\r')
    s.until(lambda: 'type CTRL/Y' in s.text(), 20)
    s.child.send('\x19')
    check('ctrl-y-dcl', s.until(lambda: 'Interrupt' in s.text() and s.prompted(), 20), s)

    s.child.send('logout\r')
    s.pump(3)
    passed = results.count(True)
    line = 'TTY: %d passed, %d failed' % (passed, len(results) - passed)
    print(line)
    log.write(line + '\n')
    sys.exit(0 if all(results) else 1)


if __name__ == '__main__':
    main()
