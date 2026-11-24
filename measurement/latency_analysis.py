#!/usr/bin/env python3
"""latency_analysis.py - aggregate the matrix CSV into the paper's numbers.

Per mode x scenario x phase: n, mean, p50, p95, p99, and the added-latency
ratio of defended vs baseline (the "<10 percent" target in the evaluation
table). Writes an aggregated CSV and, if matplotlib is available, a CDF plot
per scenario. Pure stdlib otherwise.

Usage: latency_analysis.py --csv summary.csv --out report_dir
"""
import argparse
import csv
import math
import os
import statistics
from collections import defaultdict

PHASES = ["session_setup", "discovery", "payment_details", "authorization", "total"]


def pct(values, q):
    if not values:
        return ""
    s = sorted(values)
    k = max(0, min(len(s) - 1, math.ceil(q * len(s)) - 1))
    return round(s[k], 3)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    cells = defaultdict(lambda: defaultdict(list))  # (mode,scen) -> phase -> [ms]
    completed = defaultdict(int)
    total_runs = defaultdict(int)
    with open(args.csv) as fh:
        for row in csv.DictReader(fh):
            key = (row.get("mode", "?"), row.get("scenario", "?"))
            total_runs[key] += 1
            completed[key] += int(row.get("completed") or 0)
            for ph in PHASES:
                v = row.get(f"{ph}_ms")
                if v:
                    cells[key][ph].append(float(v))

    agg_path = os.path.join(args.out, "aggregate.csv")
    with open(agg_path, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["mode", "scenario", "runs", "completed", "phase", "n",
                    "mean_ms", "p50_ms", "p95_ms", "p99_ms"])
        for (mode, scen), phases in sorted(cells.items()):
            for ph in PHASES:
                vals = phases.get(ph, [])
                if not vals:
                    continue
                w.writerow([mode, scen, total_runs[(mode, scen)],
                            completed[(mode, scen)], ph, len(vals),
                            round(statistics.fmean(vals), 3),
                            pct(vals, 0.5), pct(vals, 0.95), pct(vals, 0.99)])
    print(f"wrote {agg_path}")

    # Defended-vs-baseline overhead on the phases the defense touches
    lines = []
    scenarios = sorted({s for (_, s) in cells})
    for scen in scenarios:
        for ph in ("payment_details", "authorization", "total"):
            base = cells.get(("baseline", scen), {}).get(ph, [])
            dfd = cells.get(("defended", scen), {}).get(ph, [])
            if base and dfd:
                overhead = (statistics.fmean(dfd) / statistics.fmean(base) - 1) * 100
                lines.append(f"{scen:12s} {ph:16s} overhead vs baseline: {overhead:+.2f}%")
    rep = os.path.join(args.out, "overhead.txt")
    with open(rep, "w") as fh:
        fh.write("Defended-mode added handshake latency (target: under 10 percent)\n")
        fh.write("\n".join(lines) + "\n")
    print(f"wrote {rep}")
    for line in lines:
        print(" ", line)

    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        for scen in scenarios:
            plt.figure()
            for mode in sorted({m for (m, s) in cells if s == scen}):
                vals = sorted(cells[(mode, scen)].get("total", []))
                if vals:
                    y = [(i + 1) / len(vals) for i in range(len(vals))]
                    plt.plot(vals, y, label=mode)
            plt.xlabel("total handshake latency (ms)")
            plt.ylabel("CDF")
            plt.title(f"PnC handshake latency, scenario {scen}")
            plt.legend()
            plt.savefig(os.path.join(args.out, f"cdf-total-{scen}.png"), dpi=150)
            plt.close()
        print("wrote CDF plots")
    except ImportError:
        print("matplotlib not installed - skipping CDF plots (CSV outputs are complete)")


if __name__ == "__main__":
    main()
