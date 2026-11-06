#!/usr/bin/env bash
# build.sh <node> [ALL|CLEAN] - push the prepared tree and run [.VMSPORT]BUILD.COM on <node>:
# links the launcher [.BIN]MVN.EXE and compiles the patched classes into lib/.
# The log is printed and saved to out/build-<node>.log.
set -euo pipefail

top=$(cd "$(dirname "$0")/.." && pwd)
node=${1:?usage: build.sh <node> [ALL|CLEAN]}
target=${2:-ALL}
. "$top/upstream.conf"
remote=$(echo "$UPSTREAM_NAME-$UPSTREAM_VERSION" | tr . _ | tr a-z A-Z)
read -r _ _ _ _ _ WORKDIR _ < <(awk -v n="$node" '$1==n' "$top/tools/nodes.conf")

"$top/tools/push.sh" "$node"
mkdir -p "$top/out"
job=$top/cache/build-$node.com
cat > "$job" <<DCL
\$ set noon
\$ set process/parse_style=extended
\$ purge/nolog ${WORKDIR%]}.$remote...]*.*
\$ @${WORKDIR%]}.$remote.VMSPORT]BUILD.COM $target
DCL
VMS_TIMEOUT=${VMS_BUILD_TIMEOUT:-1800} "$top/tools/vms.sh" "$node" run "$job" | tee "$top/out/build-$node.log"
grep -aq 'BUILD: done' "$top/out/build-$node.log"
if grep -aE 'USEUNDEF|UNDFSYM|%DCL-[WEF]-|%CC-[EF]-|%I?LINK-[EF]-|BUILD-E-| error: |^[0-9]+ errors?$' \
        "$top/out/build-$node.log" >&2; then
    echo "build: errors in out/build-$node.log" >&2
    exit 1
fi
