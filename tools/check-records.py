#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
"""Check the record sets under records/<host class>/<set>/ the way plugin-qualify-sync will read them.

    tools/check-records.py [<set dir> ...]

Without arguments every set under records/ is checked. A set passes when:

- its provenance.json is plugin-qualify.distributed-provenance/1, names the set and host class of its directory,
  and the package omx-qualification-<host class>-<set>;
- every *.qualification.json is a plugin-qualify.qualification-record/1 with its binary's files and its probe output
  beside it, whose size and SHA-256 are the ones the record names (a record with no verdict for the provenance's
  hostProfile is counted and named, not refused: the sync only skips it under that host);
- every *.probe.json is the probe output of a record (nothing is shipped that no record judged);
- nothing else is in the directory (no *.unmeasured.json: an unmeasured record never applies).

The exit code is 0 when every set passes and 1 otherwise; each problem is printed on its own line.
"""
import hashlib
import json
import os
import sys

RECORD = ".qualification.json"
PROBE = ".probe.json"
PROVENANCE_SCHEMA = "plugin-qualify.distributed-provenance/1"
RECORD_SCHEMA = "plugin-qualify.qualification-record/1"


def check_set(path):
    problems = []
    path = os.path.normpath(path)
    set_name = os.path.basename(path)
    host_class = os.path.basename(os.path.dirname(path))

    def bad(name, why):
        problems.append(f"{path}/{name}: {why}")

    try:
        with open(os.path.join(path, "provenance.json"), encoding="utf-8") as f:
            prov = json.load(f)
    except (OSError, ValueError) as e:
        bad("provenance.json", f"does not read ({e})")
        return problems, 0
    if prov.get("schema") != PROVENANCE_SCHEMA:
        bad("provenance.json", f"schema is {prov.get('schema')!r}, not {PROVENANCE_SCHEMA}")
    if prov.get("set") != set_name or prov.get("hostClass") != host_class:
        bad("provenance.json", f"names set {prov.get('set')!r} and host class {prov.get('hostClass')!r}, not its directory's")
    want = f"omx-qualification-{host_class}-{set_name}"
    if (prov.get("package") or {}).get("name") != want:
        bad("provenance.json", f"names the package {(prov.get('package') or {}).get('name')!r}, not {want}")
    host = prov.get("hostProfile")
    if not isinstance(host, str) or not host:
        bad("provenance.json", "names no hostProfile")

    names = sorted(os.listdir(path))
    judged = set()
    records = 0
    without_verdict = 0
    for name in names:
        if name == "provenance.json" or name.endswith(PROBE):
            continue
        if not name.endswith(RECORD):
            bad(name, "is neither a record, a probe output nor the provenance")
            continue
        records += 1
        try:
            with open(os.path.join(path, name), encoding="utf-8") as f:
                rec = json.load(f)
        except (OSError, ValueError) as e:
            bad(name, f"does not read ({e})")
            continue
        if rec.get("schema") != RECORD_SCHEMA:
            bad(name, f"schema is {rec.get('schema')!r}")
        binary = rec.get("binary") or {}
        files = binary.get("files")
        if not isinstance(binary.get("path"), str) or not isinstance(files, list) or not files:
            bad(name, "names no binary with its files")
        elif any(not isinstance(x.get("path"), str) or len(str(x.get("sha256", ""))) != 64 for x in files):
            bad(name, "a file of its binary has no path or no SHA-256")
        if isinstance(host, str) and not any(v.get("host") == host for v in rec.get("verdicts") or []):
            without_verdict += 1
        probe = rec.get("probe") or {}
        pname = probe.get("file")
        if not isinstance(pname, str) or not pname.endswith(PROBE) or os.path.basename(pname) != pname:
            bad(name, f"names no probe output beside it ({pname!r})")
            continue
        judged.add(pname)
        try:
            with open(os.path.join(path, pname), "rb") as f:
                data = f.read()
        except OSError:
            bad(name, f"its probe output {pname} is missing")
            continue
        if probe.get("bytes") is not None and probe.get("bytes") != len(data):
            bad(pname, f"is {len(data)} bytes, the record says {probe.get('bytes')}")
        if hashlib.sha256(data).hexdigest() != probe.get("sha256"):
            bad(pname, "does not hash as its record says")
    for name in names:
        if name.endswith(PROBE) and name not in judged:
            bad(name, "is the probe output of no record")
    if records == 0:
        problems.append(f"{path}: holds no record")
    if without_verdict:
        print(f"{path}: {without_verdict} records hold no verdict for {host} and never apply under it")
    return problems, records


def main(argv):
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "records")
    sets = argv or sorted(
        os.path.join(root, c, s)
        for c in os.listdir(root)
        for s in os.listdir(os.path.join(root, c))
        if os.path.isdir(os.path.join(root, c, s))
    )
    failed = False
    for s in sets:
        problems, records = check_set(s)
        for p in problems:
            print(p)
        failed = failed or bool(problems)
        print(f"{os.path.normpath(s)}: {records} records, {'FAILED' if problems else 'ok'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
