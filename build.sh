#!/bin/bash
# Build the Unraid package and stamp its version + MD5 into zfs.backups.plg.
#
#   ./build.sh               version = today's date (YYYY.MM.DD)
#   ./build.sh 2026.10.17a   explicit version (use a letter suffix for same-day releases)
#
# Remember to add a matching entry under <CHANGES> in zfs.backups.plg.
set -euo pipefail
cd "$(dirname "$0")"

NAME=zfs.backups
VERSION=${1:-$(date +%Y.%m.%d)}
[[ $VERSION =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}[a-z]?$ ]] || { echo "bad version '$VERSION'" >&2; exit 1; }
PKG="packages/$NAME-$VERSION-noarch-1.txz"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R src/. "$STAGE/"
find "$STAGE" -name '.DS_Store' -delete
mkdir -p "$STAGE/install"
cat > "$STAGE/install/slack-desc" <<EOF
$NAME: ZFS Backups for Unraid
$NAME:
$NAME: Scheduled ZFS snapshots with per-job retention (sanoid), replication
$NAME: (syncoid or rsync), folder-to-dataset conversion and array disk
$NAME: wake-up, managed from the Unraid WebGUI.
$NAME:
$NAME: https://github.com/frequencylost/ZFS-Backups
$NAME:
$NAME:
$NAME:
$NAME:
EOF

P="$STAGE/usr/local/emhttp/plugins/$NAME"
find "$STAGE" -type d -exec chmod 755 {} +
find "$STAGE" -type f -exec chmod 644 {} +
chmod 755 "$P/scripts/zfsb" "$P/vendor/sanoid" "$P/vendor/syncoid"

if tar --version 2>/dev/null | grep -q bsdtar; then
  TAR_OPTS=(--uid 0 --gid 0 --uname root --gname root --no-xattrs --no-mac-metadata)
else
  TAR_OPTS=(--owner=0 --group=0 --numeric-owner)
fi
mkdir -p packages
rm -f "$PKG"
COPYFILE_DISABLE=1 tar "${TAR_OPTS[@]}" -cJf "$PKG" -C "$STAGE" .

MD5=$( (md5sum "$PKG" 2>/dev/null || md5 -r "$PKG") | cut -d' ' -f1)
perl -pi -e "s|<!ENTITY version .*|<!ENTITY version   \"$VERSION\">|; s|<!ENTITY pkgMD5 .*|<!ENTITY pkgMD5    \"$MD5\">|" "$NAME.plg"

echo "built $PKG"
echo "  md5     $MD5"
echo "  files   $(tar -tJf "$PKG" | grep -vc '/$')"
grep -q "###$VERSION" "$NAME.plg" || echo "  NOTE: add a '###$VERSION' entry under <CHANGES> in $NAME.plg"
