#!/usr/bin/env bash
# installcheck.sh <node> - install the node's kit, verify it, run the smoke test
# against the installed MVN (a batch job, as test.sh runs it), and remove the kit
# again.  This changes the system while it runs (PCSI database, SYS$COMMON:[MAVEN],
# SYS$STARTUP:MAVEN$STARTUP.COM, MAVEN$ROOT): ask the user first.  Run kit.sh first.
# Output: out/install-<node>.txt.
set -euo pipefail
top=$(cd "$(dirname "$0")/.." && pwd)
node=${1:?usage: installcheck.sh <node>}
. "$top/upstream.conf"
REMOTE=$(echo "$UPSTREAM_NAME-$UPSTREAM_VERSION" | tr . _ | tr a-z A-Z)
"$top/tools/vms.sh" "$node" put "$top/tools/vms_installcheck.com" >/dev/null
read -r _ _ _ _ _ WORKDIR _ < <(awk -v n="$node" '$1==n' "$top/tools/nodes.conf")
out=$top/out/install-$node.txt
mkdir -p "$top/out"
step() {  # step <INSTALL|SMOKE|REMOVE> <run|batch>
    local job=$top/cache/installcheck-$1-$node.com
    printf '$ set noon\n$ @%sVMS_INSTALLCHECK.COM %s %s\n' "$WORKDIR" "$REMOTE" "$1" > "$job"
    VMS_TIMEOUT=1800 VMS_SUBMIT_QUALS=/CPUTIME=01:00:00 "$top/tools/vms.sh" "$node" "$2" "$job" || true
}
{ step INSTALL run; step SMOKE batch; step REMOVE run; } > "$out" 2>&1
grep -aE 'install status|ISSINOHO|startup procedure|MAVEN\$ROOT|setup status|MVN ==|lib jars|Apache Maven|Maven home|mvn -v status|PASS|FAIL|SMOKE:|remove status|after removal|items found' "$out"
grep -aq 'install status %X00000001' "$out" &&
    grep -aq 'lib jars: [1-9][0-9]*, upper case: 0' "$out" &&
    grep -aq 'mvn -v status: %X00000001' "$out" &&
    grep -aq 'SMOKE: [0-9]* passed, 0 failed' "$out" &&
    grep -aq 'remove status %X00000001' "$out" &&
    grep -aq 'MAVEN\$ROOT after removal: \[\]' "$out" &&
    grep -aq 'files after removal: \[\]' "$out" &&
    grep -aq 'directory after removal: \[\]' "$out" &&
    grep -aq 'startup after removal: \[\]' "$out"
