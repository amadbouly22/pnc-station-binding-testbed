# Plug & Charge defense testbed

A software-only experiment testbed for the paper defending ISO 15118 Plug &
Charge against the relay attack (arXiv:2512.15966) and the PKI
certificate-reuse weakness (arXiv:2404.06635). No lab, no car, no charger: a
Linux machine or small cloud VM (4+ GB RAM) runs everything. Prepared
22 Nov 2026 against EVerest manual 2026.10.0-rc3 and the current EVerest
monorepo.

## What is verified and what runs where

Verified when this scaffold was prepared (in a sandbox without Docker or
network admin rights, so network-dependent runs are packaged, not executed):

- The attack authors' PoC repo clones, installs and imports cleanly
  (with 4 dependency pins pip misses; encoded in scripts/40).
- **Bug found and fixed in the upstream PoC**: its create_certs.sh references
  configs/secc2LeafCert.cnf, which the repo never shipped, so the
  "compromised station" certificate was never generated. This scaffold's
  configs/secc2LeafCert.cnf fixes it; verified: both station certificates
  generate and chain-validate under the same V2G root with distinct CNs.
- The full ISO 15118-2 test PKI generates with create_certs.sh.
- The attack's cryptographic invariant holds against the real PKI
  (measurement/verify_attack_invariant.py): a relayed challenge signature
  verifies at the honest station; the wrong-station certificate passes chain
  validation; the station-binding defense rejects the relayed signature.
- Crypto cost on the real contract key: sign ~25 us, verify ~65 us, defense
  payload delta ~0 us (measurement/crypto_bench.py).
- The measurement chain (parse_logs.py -> latency_analysis.py) runs
  end-to-end on synthetic logs and produces summary/aggregate/overhead CSVs
  and CDF plots.
- All shell scripts pass bash -n; all Python compiles; JSON/YAML validated.

Needs the user's machine (root + interfaces): the four-process attack runs
(scripts/40, 50), EVerest builds and SIL runs (10/15/20/30), netem (60), and
the experiment matrix (80). Each is one command; see below.

## Quick start

```bash
# 0. One-time host setup (Ubuntu 22.04/24.04)
scripts/00-prereqs-ubuntu.sh && source ~/.bashrc   # re-login for docker group

# 1. Phase 1: EVerest baseline (docker OR native) + infra + clean traces
scripts/10-build-everest-docker.sh     # or scripts/15-build-everest-native.sh
scripts/20-start-infra.sh
scripts/30-baseline-pnc-everest.sh

# 2. Phase 2: the attacks (the core reproduction, ~10 minutes)
sudo scripts/05-setup-veth.sh
scripts/40-relay-attack-josev.sh       # relay attack, paper's own PoC
scripts/50-pki-cert-reuse-mitm.sh      # wrong-station certificate MitM

# 3. Phase 3/4: defense + measurements
sudo scripts/60-netem-plc.sh --profile plc-typical
sudo scripts/80-run-experiment-matrix.sh --runs 1000 \
     --modes baseline,defended --scenarios plc-clean,plc-typical,plc-noisy
```

Success criteria and evidence per experiment: docs/measurement-plan.md.

## Repository layout

    configs/     secc2LeafCert.cnf (PoC fix), evcc_config_pnc.json,
                 plc-latency-profiles.json, everest/config-honest-charger.yaml
    scripts/     numbered runbooks: prereqs, veth, EVerest builds, infra,
                 baseline, both attacks, netem, experiment matrix
    measurement/ capture_traffic.sh, parse_logs.py, latency_analysis.py,
                 crypto_bench.py, verify_attack_invariant.py
    defense/     defense design + josev patch points (station binding,
                 freshness, PKI profile)
    docs/        methodology-map.md (outline phase -> scaffold piece),
                 measurement-plan.md, pki-hardening-profile.md,
                 everest-patch-points.md (C++ patch locations)
    results/     all experiment output lands here

## Key design decisions (read before changing anything)

1. **The attack reproduction uses the authors' published PoC**, a fork of the
   Josev (ex-SwitchEV/EcoG) ISO 15118 stack - the same stack EVerest used for
   EV-side simulation until its C++ rewrite (Ev15118). This is the fastest,
   most faithful path to reproduced attacks with the paper's own evidence
   format (pcapng + ssl keylog).
2. **EVerest's role**: Phase-1 baseline traces from an independent
   industry-grade implementation, and the conformance target for the defense
   port (exact patch points in docs/everest-patch-points.md). EVerest's SIL
   simulates CP/SLAC inside one process pair, so external stacks cannot
   transparently replace one side; docs/everest-patch-points.md section
   "Crossing the SIL boundary" explains the adaptation of the outline's
   "third EVerest instance as fake charger" and scripts/45 is the
   experimental integration harness.
3. **The defense is implemented where the attack lives** (josev patch,
   behind a DEFENDED flag), so one testbed runs baseline, attack and defended
   modes; the EVerest C++ port follows the documented patch points.
4. **The freshness bound is measured, not chosen**: the netem matrix sweeps
   PLC latency profiles and reports false-reject rates; station binding alone
   blocks the billing attack regardless.

## Sources

- Relay attack: Löw et al., "Charge It to My Neighbor", arXiv:2512.15966v2
  (USENIX VehicleSec '26); PoC: github.com/securityinmobility/plug-and-charge-relay-poc
- PKI study: Szakály et al., "Current Affairs", arXiv:2404.06635
- EVerest: github.com/EVerest/EVerest, everest.github.io (PnC SIL tutorial,
  quick start, both checked 2026-11-22); CSMS: github.com/EVerest/ocpp-csms
- Josev stack: github.com/EcoG-io/iso15118 (v0.28.3)
- Wireshark dissector: github.com/chargebyte/dsV2Gshark

## Results summary (from the paper)

- 300 relay-attack runs: the attack succeeded in all 150 runs against the
  unmodified stack and was blocked in all 150 runs against the defended
  stack, every time on the station-binding check.
- 300 ordinary sessions: mean handshake latency differed between modes by at
  most 0.8 percent; session completion was not lower with the defense.
- Crypto microbenchmark (2000 iterations): ECDSA P-256 sign about 25 us,
  verify about 65 us; the defense payload adds nothing measurable.

## License

Apache License 2.0 (see LICENSE). The defense patch derives from
EcoG-io/iso15118 (Apache-2.0). This repository contains only original
scaffolding and patches against pinned upstream commits; the relay-attack
proof of concept is cloned from its public repository by scripts/40 at run
time, so no third-party code is redistributed here.

## Citing

See CITATION.cff. Companion paper: "Station Binding Against the ISO 15118
Plug and Charge Relay Attack: Implementation and Evaluation on a
Reproducible Software Testbed" (venue pending).
