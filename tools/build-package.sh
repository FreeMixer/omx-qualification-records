#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
#
# Build the records package with plugin-qualify-records-package (plugin-qualify >= 0.17.0), either over the records
# this repository holds or from a new device run.
#
#   tools/build-package.sh [--out <dir>]
#       builds the .deb of records/<class>/<set>/ with the tool, for a comparison with the package the release
#       builds from debian/ (same files, same bytes). The version is the debian/changelog one.
#
#   tools/build-package.sh --from <qualification dir> --provenance <json> --version <version> --host-class <class> --set <set>
#       takes a device's qualification directory (plugin-qualify-sync's qualification_dir): the tool judges which
#       records go in (a record with its probe copy intact; never an unmeasured one), builds the package, and the
#       records, provenance.json and debian/ (control, install, changelog entry) of this tree are replaced by what
#       the package holds. Review the diff, commit, tag v<version>. For the set the RPM spec builds
#       (packaging/omx-qualification-records.spec names its host class and set), only that set's records and the
#       spec's Version change; the tool's .deb is used for its judgement of which records go in and is discarded.
#
# plugin-qualify comes from the OpenMixer channel (apt) or, where that is not configured, from npm.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
out=$root/out
from=
provenance=
version=
class=
set_=
while [ $# -gt 0 ]; do
    case $1 in
        --out) out=$2; shift 2 ;;
        --from) from=$2; shift 2 ;;
        --provenance) provenance=$2; shift 2 ;;
        --version) version=$2; shift 2 ;;
        --host-class) class=$2; shift 2 ;;
        --set) set_=$2; shift 2 ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac
done

if ! command -v plugin-qualify-records-package >/dev/null; then
    if command -v apt-get >/dev/null && apt-cache policy plugin-qualify 2>/dev/null | grep -q 'Candidate: [0-9]'; then
        apt-get install -y --no-install-recommends plugin-qualify
    else
        npm install -g @openmixer/plugin-qualify
    fi
fi
tool=$(command -v plugin-qualify-records-package)

if [ -z "$from" ]; then
    dir=$(find "$root/records" -mindepth 2 -maxdepth 2 -type d | sort | head -1)
    class=$(basename "$(dirname "$dir")")
    set_=$(basename "$dir")
    version=$(sed -n '1s/^[^(]*(\([^)]*\)).*/\1/p' "$root/debian/changelog")
    "$tool" "$dir" --host-class "$class" --set "$set_" --provenance "$dir/provenance.json" --version "$version" --out "$out"
    exit 0
fi

: "${provenance:?--provenance is needed}" "${version:?--version is needed}" "${class:?--host-class is needed}" "${set_:?--set is needed}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
"$tool" "$from" --host-class "$class" --set "$set_" --provenance "$provenance" --version "$version" --out "$tmp"
deb=$(ls "$tmp"/*.deb)
name=$(basename "$deb" | cut -d_ -f1)
rel=usr/share/omx/qualification/$class/$set_
(cd "$tmp" && ar x "$deb" && tar -xJf data.tar.xz "./$rel" && tar -xJf control.tar.xz ./control)
# a host comparison was measured on the old set's plugins: it goes with them, and the new set's is added after
if ls "$root/records/$class/$set_/"*.comparison.json >/dev/null 2>&1; then
    echo "records/$class/$set_: its host comparison is dropped with the old records; add the new set's (README, \"The host comparison\")" >&2
fi
rm -rf "${root:?}/records/$class/$set_"
mkdir -p "$root/records/$class"
cp -r "$tmp/$rel" "$root/records/$class/$set_"
# a set the RPM spec builds (packaging/omx-qualification-records.spec): the records are the tool's, the package is
# the spec's; debian/ is the Debian set's and stays as it is
spec=$root/packaging/omx-qualification-records.spec
if grep -qx "%global host_class $class" "$spec" && grep -qx "%global set_name $set_" "$spec"; then
    sed -i "s/^Version: .*/Version: $version/" "$spec"
    echo "omx-qualification-$class-$set_ $version (RPM): $(ls "$root/records/$class/$set_" | wc -l) files; review git diff"
    exit 0
fi
# the package's own control is the source of debian/control: its Depends and Description follow the tool
depends=$(sed -n 's/^Depends: //p' "$tmp/control")
{
    sed -n '/^Source:/,/^$/p' "$root/debian/control"
    printf 'Package: %s\nArchitecture: all\nMulti-Arch: foreign\nDepends: ${misc:Depends}, %s\n' "$name" "$depends"
    sed -n '/^Description:/,$p' "$tmp/control"
} > "$tmp/control.new"
mv "$tmp/control.new" "$root/debian/control"
echo "records/$class/$set_ usr/share/omx/qualification/$class" > "$root/debian/install"
sed -i "1s/^\\([a-z0-9.+-]*\\) (.*) unstable/\\1 ($version) unstable/" "$root/debian/changelog"
echo "$name $version: $(ls "$root/records/$class/$set_" | wc -l) files; review git diff"
