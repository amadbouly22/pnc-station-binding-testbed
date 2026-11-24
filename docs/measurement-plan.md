# Measurement plan

Produces the three families of numbers the outline's evaluation section
requires: security, performance, deployability.

## 1. Security

| Experiment | Script | Success criterion | Evidence |
|---|---|---|---|
| Relay vs baseline | scripts/40-relay-attack-josev.sh | Honest station accepts relayed signature; attacker car reaches ChargeParameterDiscovery | logs, pcapng, ssl-keylog.txt |
| Cert-reuse MitM vs baseline | scripts/50-pki-cert-reuse-mitm.sh | Car completes TLS with wrong-station cert | logs + cert CN dump |
| Relay vs defended | matrix mode=defended + attack topology | Authorization rejected (station binding); freshness violation flagged | EVCC/SECC logs, abort marker |
| MitM vs defended | matrix | Session aborted before PaymentDetails | EVCC log |
| One-side-patched | matrix with defended EVCC + baseline SECC and vice versa | Session completes (backward compat) or fails safe, documented | summary.csv |

Reference captures from the attack authors ship in their repo (`*.pcapng`);
ours land in `results/`. Decode with Wireshark + dsV2Gshark
(github.com/chargebyte/dsV2Gshark) plus the `ssl-keylog.txt` the PoC stack
writes (TLS decryption).

## 2. Performance

- **Latency distribution:** >= 1,000 handshakes per mode x scenario via
  scripts/80-run-experiment-matrix.sh. Phases per run: session_setup,
  discovery, payment_details (GenChallenge issuance), authorization
  (signature verification), total. measurement/parse_logs.py ->
  summary.csv; measurement/latency_analysis.py -> aggregate.csv with
  mean/p50/p95/p99 and CDF plots per scenario, plus the defended-vs-baseline
  overhead ratio (paper target: under 10 percent).
- **Crypto cost:** measurement/crypto_bench.py - ECDSA P-256 sign/verify on
  the real contract key, baseline payload vs bound payload. (Sandbox
  measurement, 2026-11-22: sign ~25 us, verify ~65 us, defense delta ~0 us;
  re-measure on the target hardware under container CPU limits -
  `docker run --cpus=0.5` approximates charger-class hardware; EVCC-class
  ARM limits can be approximated with `--cpus` + cpufreq docs.)
- **Message overhead:** byte delta of AuthorizationReq with the extra
  SignedInfo reference - measure from the pcaps (V2GTP payload length field)
  and report bytes added per session.

## 3. The latency model (honesty of the freshness check)

tc netem profiles in configs/plc-latency-profiles.json: plc-clean (5 ms),
plc-typical (15 ms), plc-noisy (30 ms + loss), relay-cellular (+40 ms on the
relay leg), relay-wifi (+10 ms). These are STARTING POINTS: calibrate against
published HomePlug GreenPHY measurements (the e-Energy 2025 sniffing paper,
arXiv:2404.06635's modem data, and the HPGP whitepaper) and cite the chosen
parameters. The evaluation sweeps the profiles and reports the freshness
bound's false-reject rate per profile - this is the mitigation the outline's
risk section promises, and station binding remains effective even where the
timing bound is loose.

## 4. Deployability

- Message changes: one extra SignedInfo reference in AuthorizationReq, one
  optional field use in certificates (Locality). Count and list them.
- Backward compatibility: mixed-mode matrix runs (one side patched).
- Standards diff: docs/everest-patch-points.md names every code location the
  change touches; the same list doubles as the "changes to the standard"
  table row.

## Directory layout of results

    results/
      baseline-everest/<timestamp>/   phase-1 traces (EVerest SIL)
      matrix-<timestamp>/<mode>/<scenario>/run-N/  logs (+ shared/ artifacts for attack runs)
      matrix-<timestamp>/summary.csv  per-run phase timings
      matrix-<timestamp>/report/      aggregate.csv, overhead.txt, CDF plots
