#!/usr/bin/env python3
"""
hd_inspect_runs.py - READ-ONLY inspector for GatesFX_HistoricalDiscovery run folders.

Usage:
  python hd_inspect_runs.py "<...>\\Common\\Files\\GatesFX_HistoricalDiscovery"
  python hd_inspect_runs.py --sha256 file1 file2 ...

Never writes, moves or deletes anything. Classifies every run as one of:
  COMPLETE_VERIFIED, COMPLETE_MISMATCH, INCOMPLETE_RESUMABLE,
  INCOMPLETE_NO_VALID_CHECKPOINT, INIT_FAILED, EMPTY
"""
import hashlib
import json
import os
import sys
import zlib


def crc_hex(b):
    return "%08X" % (zlib.crc32(b) & 0xFFFFFFFF)


def read_bytes(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError:
        return None


def load_ckpt(path):
    raw = read_bytes(path)
    if raw is None or len(raw) < 10 or raw[8:9] != b"\n":
        return None
    head = raw[:8].decode("ascii", "replace")
    body = raw[9:]
    if head != crc_hex(body):
        return None
    try:
        return json.loads(body.decode("ascii"))
    except ValueError:
        return None


def best_ckpt(rdir):
    cands = [c for c in (load_ckpt(os.path.join(rdir, n))
                         for n in ("checkpoint_A.json", "checkpoint_B.json")) if c]
    return max(cands, key=lambda c: c.get("seq", -1)) if cands else None


def count_rows(path):
    raw = read_bytes(path)
    if raw is None:
        return None
    return max(raw.count(b"\n") - 1, 0)  # minus header


def inspect_run(rdir):
    name = os.path.basename(rdir)
    files = set(os.listdir(rdir))
    notes = []
    if "init_failed.txt" in files:
        return name, "INIT_FAILED", ["init_failed.txt present"]
    if "completion.json" in files:
        raw = read_bytes(os.path.join(rdir, "completion.json"))
        try:
            comp = json.loads(raw.decode("ascii"))
        except (ValueError, AttributeError):
            return name, "COMPLETE_MISMATCH", ["completion.json unreadable"]
        ok = True
        man = read_bytes(os.path.join(rdir, "manifest.json"))
        if man is None or crc_hex(man) != comp.get("manifest_crc32"):
            ok = False
            notes.append("manifest CRC does not match completion.json")
        dq = read_bytes(os.path.join(rdir, "data_quality.csv"))
        if dq is None:
            ok = False
            notes.append("data_quality.csv missing")
        else:
            if "dq_csv_crc32" in comp and crc_hex(dq) != comp["dq_csv_crc32"]:
                ok = False
                notes.append("data_quality.csv CRC mismatch")
            if "dq_csv_bytes" in comp and len(dq) != comp["dq_csv_bytes"]:
                ok = False
                notes.append("data_quality.csv size mismatch")
            rows = count_rows(os.path.join(rdir, "data_quality.csv"))
            if "dq_rows" in comp and rows != comp["dq_rows"]:
                ok = False
                notes.append("row count %s != dq_rows %s" % (rows, comp["dq_rows"]))
        notes.append("status=%s" % comp.get("status"))
        return name, "COMPLETE_VERIFIED" if ok else "COMPLETE_MISMATCH", notes
    ck = best_ckpt(rdir)
    if ck:
        notes.append("last valid checkpoint seq=%s m15_bars=%s m1_bars=%s dq_rows=%s"
                     % (ck.get("seq"), ck.get("m15_bars"), ck.get("m1_bars"), ck.get("dq_rows")))
        rows = count_rows(os.path.join(rdir, "data_quality.csv"))
        notes.append("data_quality.csv rows on disk=%s (>= checkpoint dq_rows expected)" % rows)
        if rows is None or rows < ck.get("dq_rows", 0):
            return name, "INCOMPLETE_NO_VALID_CHECKPOINT", notes + ["csv shorter than checkpoint claims"]
        return name, "INCOMPLETE_RESUMABLE", notes
    if "manifest.json" in files or "claim.txt" in files:
        return name, "INCOMPLETE_NO_VALID_CHECKPOINT", ["no completion marker and no valid checkpoint"]
    return name, "EMPTY", []


def main(argv):
    if len(argv) >= 2 and argv[1] == "--sha256":
        for p in argv[2:]:
            data = read_bytes(p)
            print("%s  %s" % (hashlib.sha256(data).hexdigest() if data is not None else "UNREADABLE", p))
        return 0
    if len(argv) != 2:
        print(__doc__)
        return 2
    runs = os.path.join(argv[1], "Runs")
    if not os.path.isdir(runs):
        print("No Runs folder at", runs)
        return 1
    for entry in sorted(os.listdir(runs)):
        rdir = os.path.join(runs, entry)
        if os.path.isdir(rdir):
            name, verdict, notes = inspect_run(rdir)
            print("%-40s %s" % (name, verdict))
            for n in notes:
                print("    - " + n)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
