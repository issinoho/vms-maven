#!/usr/bin/env bash
# prepare.sh - build the VMS-ready tree in staging/apache-maven-<version>/
#
#   1. fetch + verify the distribution and the sources jars (fetch.sh)
#   2. extract the distribution
#   3. unpack, from each patched jar's -sources.jar, the files the patches touch
#      into vmsport/src/<artifact>/, and list them in vmsport/patched.lis
#   4. apply patches/series, then lay overlay/ over the top
#
# Nothing in staging/ is ever edited by hand: fix things in patches/ or overlay/.
set -euo pipefail

top=$(cd "$(dirname "$0")/.." && pwd)
. "$top/upstream.conf"
name=$UPSTREAM_NAME-$UPSTREAM_VERSION
stage=$top/staging/$name

step() { echo "prepare: $*"; }
die() { echo "prepare: error: $*" >&2; exit 1; }

"$top/tools/fetch.sh" >/dev/null

step "extracting $name"
rm -rf "$stage"
mkdir -p "$top/staging"
tar -xzf "$top/cache/$(basename "$UPSTREAM_URL")" -C "$top/staging"
[ -d "$stage/lib" ] || die "tarball did not unpack to $stage"

# Files the patches change under vmsport/src/<artifact>/.
touched=$(while read -r p; do
              case $p in ''|'#'*) continue ;; esac
              sed -n 's|^+++ b/\(vmsport/src/[^[:space:]]*\).*|\1|p' "$top/patches/$p"
          done < "$top/patches/series" | sort -u)
mkdir -p "$stage/vmsport/src"
: > "$stage/vmsport/patched.lis"
while read -r gav _ _; do
    [ -n "$gav" ] || continue
    IFS=: read -r _ a v <<< "$gav"
    [ -f "$stage/lib/$a-$v.jar" ] || die "PATCHED_JARS: lib/$a-$v.jar is not in the distribution"
    files=$(grep "^vmsport/src/$a/" <<< "$touched" | sed "s|^vmsport/src/$a/||" || true)
    [ -n "$files" ] || die "PATCHED_JARS names $a, but no patch touches vmsport/src/$a/"
    step "sources: $a-$v ($(wc -w <<< "$files") files)"
    unzip -q -o "$top/cache/sources/$a-$v-sources.jar" $files -d "$stage/vmsport/src/$a"
    for f in $files; do echo "$a $v $f" >> "$stage/vmsport/patched.lis"; done
done <<< "$PATCHED_JARS"

while read -r p; do
    case $p in ''|'#'*) continue ;; esac
    step "patch $p"
    patch -d "$stage" -p1 -s --no-backup-if-mismatch -F0 < "$top/patches/$p" ||
        die "patch $p does not apply cleanly"
done < "$top/patches/series"

# overlay/ may only add files; changes to upstream files belong in patches/.
(cd "$top/overlay" && find . -type f) | while read -r f; do
    [ -e "$stage/$f" ] && die "overlay/$f would replace an upstream file; use a patch"
    true
done
cp -a "$top/overlay/." "$stage/"
printf 'MAVEN_VERSION=%s\nKIT_VERSION=%s-vms%s\n' "$UPSTREAM_VERSION" "$UPSTREAM_VERSION" \
    "$VMS_PATCH_LEVEL" > "$stage/vmsport/VERSION.ENV"

step "staged $stage"
