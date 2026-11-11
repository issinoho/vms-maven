#!/usr/bin/env bash
# test.sh <node> [smoke|projects|plugins] - run a test procedure as a batch job on <node> against
# the built tree (build.sh first):
#   smoke     [.VMSPORT]TEST_SMOKE.COM: the launcher and a one-module build (default)
#   projects  [.VMSPORT]TEST_PROJECTS.COM: a reactor, shade, install, deploy, clean, and
#             two builds at once into an empty repository
#   plugins   [.VMSPORT]TEST_PLUGINS.COM: exec:java, exec:exec, antrun, javadoc, assembly
# Both use Maven Central (the shared repository is <workdir>[.REPO]).
# Output is saved to out/<suite>-<node>.log; exit status 0 only if all tests pass.
set -euo pipefail

top=$(cd "$(dirname "$0")/.." && pwd)
node=${1:?usage: test.sh <node> [smoke|projects|plugins]}
suite=${2:-smoke}
case $suite in
    smoke) com=TEST_SMOKE.COM tag=SMOKE ;;
    projects) com=TEST_PROJECTS.COM tag=PROJECTS ;;
    plugins) com=TEST_PLUGINS.COM tag=PLUGINS ;;
    *) echo "test.sh: unknown suite '$suite'" >&2; exit 2 ;;
esac
. "$top/upstream.conf"
remote=$(echo "$UPSTREAM_NAME-$UPSTREAM_VERSION" | tr . _ | tr a-z A-Z)
read -r _ _ _ _ _ WORKDIR _ < <(awk -v n="$node" '$1==n' "$top/tools/nodes.conf")

"$top/tools/push.sh" "$node" >/dev/null
mkdir -p "$top/out"
job=$top/cache/$suite-$node.com
printf '$ set noon\n$ @%s.%s.VMSPORT]%s\n' "${WORKDIR%]}" "$remote" "$com" > "$job"
VMS_TIMEOUT=${VMS_TEST_TIMEOUT:-3000} VMS_SUBMIT_QUALS=/CPUTIME=01:00:00 \
    "$top/tools/vms.sh" "$node" batch "$job" | grep -av '^$' | tee "$top/out/$suite-$node.log"
grep -aq "$tag: [0-9]* passed, 0 failed" "$top/out/$suite-$node.log"
