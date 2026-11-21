#!/usr/bin/env bash
# kit.sh <node> - build the PCSI kit on <node> and fetch it to out/kits/.
# Builds first (via build.sh, which pushes the prepared tree), so the kit always
# matches staging/; run tools/prepare.sh first.
set -euo pipefail

top=$(cd "$(dirname "$0")/.." && pwd)
node=${1:?usage: kit.sh <node>}
. "$top/upstream.conf"
remote=$(echo "$UPSTREAM_NAME-$UPSTREAM_VERSION" | tr . _)
REMOTE=$(echo "$remote" | tr a-z A-Z)
read -r _ ARCH _ _ _ WORKDIR _ < <(awk -v n="$node" '$1==n' "$top/tools/nodes.conf")
mkdir -p "$top/out/kits"

# build.sh writes out/build-<node>.log itself; keep its console output apart.
"$top/tools/build.sh" "$node" > "$top/out/kitbuild-$node.log" 2>&1 ||
    { tail -20 "$top/out/kitbuild-$node.log"; echo "kit: build failed" >&2; exit 1; }

job=$top/cache/kit-$node.com
printf '$ set noon\n$ @%s.%s.VMSPORT.KIT]MAKE_KIT.COM\n' "${WORKDIR%]}" "$REMOTE" > "$job"
VMS_TIMEOUT=${VMS_KIT_TIMEOUT:-1800} "$top/tools/vms.sh" "$node" run "$job" | tee "$top/out/kit-$node.log"
kit=$(sed -n 's/^MAKE_KIT: kit .*\]\([^;]*\);.*/\1/p' "$top/out/kit-$node.log" | head -1)
[ -n "$kit" ] || { echo "kit: no kit produced (see out/kit-$node.log)" >&2; exit 1; }
"$top/tools/vms.sh" "$node" get "$remote/KIT_$ARCH/$kit" "$top/out/kits/$kit"
(cd "$top/out/kits" && sha256sum "$kit" > "$kit.sha256")
ls -la "$top/out/kits/$kit"; cat "$top/out/kits/$kit.sha256"
