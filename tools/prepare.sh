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

# --- PCSI kit inputs (vmsport/kit/MAKE_KIT.COM builds the kit on each node) ----
step "PCSI kit inputs"
: "${KIT_PRODUCER:=ISSINOHO}"
# D6: 3.9.16-vms1 is V3.9-16E1 (the patch number is the PCSI update, our patch
# level the ECO, as in the sibling ports).
IFS=. read -r major minor update _ <<< "$UPSTREAM_VERSION"
pcsiversion="V$major.$minor-${update:-0}E$VMS_PATCH_LEVEL"
kitversion="$UPSTREAM_VERSION-vms$VMS_PATCH_LEVEL"
kit=$stage/vmsport/kit
python3 -I "$top/tools/gen_kit.py" "$stage" "$kit" | sed 's/^/prepare: /'
subst() {
    sed -e "s/@PRODUCER@/$KIT_PRODUCER/g" -e "s/@BASE@/$1/g" \
        -e "s/@PCSIVERSION@/$pcsiversion/g" -e "s/@VERSION@/$UPSTREAM_VERSION/g" \
        -e "s/@KITVERSION@/$kitversion/g" -e "s/@ARCH@/$2/g"
}
for base in I64VMS X86VMS; do
    # awk, not sed's "r file": BSD sed (macOS) differs.
    subst $base "" < "$kit/maven.pcsi\$desc_template" |
        awk -v files="$kit/tree.pdf" '/^@TREE@$/ { while ((getline l < files) > 0) print l; next } { print }' \
        > "$kit/MAVEN-$base.PCSI\$DESC"
    subst $base "" < "$kit/maven.pcsi\$text_template" > "$kit/MAVEN-$base.PCSI\$TEXT"
done
rm -f "$kit/maven.pcsi\$desc_template" "$kit/maven.pcsi\$text_template" "$kit/tree.pdf"
mv "$kit/maven\$startup.com" "$kit/MAVEN\$STARTUP.COM"
mv "$kit/maven\$setup.com" "$kit/MAVEN\$SETUP.COM"
mv "$kit/make_kit.com" "$kit/MAKE_KIT.COM"
subst "" "IA64 and x86-64" < "$kit/readme.vms" > "$kit/README.VMS"; rm -f "$kit/readme.vms"
printf 'KIT_PRODUCER=%s\nPCSI_VERSION=%s\nKIT_VERSION=%s\n' "$KIT_PRODUCER" "$pcsiversion" \
    "$kitversion" > "$kit/KIT.ENV"

step "staged $stage"
