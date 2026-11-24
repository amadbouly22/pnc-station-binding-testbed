#!/usr/bin/env python3
"""parse_logs.py - turn josev SECC/EVCC logs into per-handshake phase timings.

josev logs one line per V2G message sent/received, with a timestamp prefix of
the form `2026-11-22 01:23:45,678`. We extract the first occurrence of each
ISO 15118-2 PnC message per run and compute phase durations:

  sdp            SDP request -> first V2GTP message (session setup)
  session_setup  SupportedAppProtocol/SessionSetup exchange
  discovery      ServiceDiscovery + PaymentServiceSelection
  payment_details  PaymentDetailsReq -> PaymentDetailsRes (GenChallenge issue)
  authorization  AuthorizationReq -> AuthorizationRes   (signature check)
  total          first -> last message of the run

Usage:
  parse_logs.py --run DIR          # one run dir holding secc.log / evcc.log
  parse_logs.py --matrix MATRIX_DIR --csv OUT.csv   # walk mode/scenario/run tree
"""
import argparse
import csv
import os
import re
import sys
from datetime import datetime

TS_RE = re.compile(r"^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2}[.,]\d+)")

MESSAGES = [
    "SessionSetupReq", "SessionSetupRes",
    "ServiceDiscoveryReq", "ServiceDiscoveryRes",
    "PaymentServiceSelectionReq", "PaymentServiceSelectionRes",
    "PaymentDetailsReq", "PaymentDetailsRes",
    "AuthorizationReq", "AuthorizationRes",
    "ChargeParameterDiscoveryReq", "ChargeParameterDiscoveryRes",
    "PowerDeliveryReq", "PowerDeliveryRes",
]

PHASES = [
    ("session_setup", "SessionSetupReq", "SessionSetupRes"),
    ("discovery", "ServiceDiscoveryReq", "PaymentServiceSelectionRes"),
    ("payment_details", "PaymentDetailsReq", "PaymentDetailsRes"),
    ("authorization", "AuthorizationReq", "AuthorizationRes"),
    ("total", "SessionSetupReq", "PowerDeliveryRes"),
]


def parse_ts(line):
    m = TS_RE.match(line)
    if not m:
        return None
    try:
        return datetime.strptime(
            f"{m.group(1)} {m.group(2)}".replace(",", "."),
            "%Y-%m-%d %H:%M:%S.%f",
        )
    except ValueError:
        return None


def first_hits(path):
    hits = {}
    if not os.path.isfile(path):
        return hits
    with open(path, errors="replace") as fh:
        for line in fh:
            ts = parse_ts(line)
            if ts is None:
                continue
            for msg in MESSAGES:
                if msg in line and msg not in hits:
                    hits[msg] = ts
    return hits


def run_row(run_dir, **labels):
    hits = {}
    for fname in ("secc.log", "evcc.log", "secc-honest.log", "evcc-attacker.log"):
        for msg, ts in first_hits(os.path.join(run_dir, fname)).items():
            hits.setdefault(msg, ts)
    row = dict(labels)
    row["messages_seen"] = len(hits)
    row["completed"] = int("AuthorizationRes" in hits)
    for name, a, b in PHASES:
        row[f"{name}_ms"] = ""
        if a in hits and b in hits and hits[b] >= hits[a]:
            row[f"{name}_ms"] = round((hits[b] - hits[a]).total_seconds() * 1000, 3)
    return row


def walk_matrix(matrix_dir):
    for mode in sorted(os.listdir(matrix_dir)):
        mode_dir = os.path.join(matrix_dir, mode)
        if not os.path.isdir(mode_dir):
            continue
        for scen in sorted(os.listdir(mode_dir)):
            scen_dir = os.path.join(mode_dir, scen)
            if not os.path.isdir(scen_dir):
                continue
            for run in sorted(os.listdir(scen_dir)):
                run_dir = os.path.join(scen_dir, run)
                if os.path.isdir(run_dir):
                    yield run_dir, {"mode": mode, "scenario": scen, "run": run}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run")
    ap.add_argument("--matrix")
    ap.add_argument("--csv", default="-")
    args = ap.parse_args()

    rows = []
    if args.run:
        rows.append(run_row(args.run))
    elif args.matrix:
        for run_dir, labels in walk_matrix(args.matrix):
            rows.append(run_row(run_dir, **labels))
    else:
        ap.error("--run or --matrix required")

    fields = ["mode", "scenario", "run", "messages_seen", "completed"] + [
        f"{n}_ms" for n, _, _ in PHASES
    ]
    out = sys.stdout if args.csv == "-" else open(args.csv, "w", newline="")
    w = csv.DictWriter(out, fieldnames=fields, extrasaction="ignore")
    w.writeheader()
    w.writerows(rows)
    if out is not sys.stdout:
        out.close()
        print(f"wrote {args.csv} ({len(rows)} runs)", file=sys.stderr)


if __name__ == "__main__":
    main()
