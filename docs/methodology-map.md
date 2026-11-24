# Methodology map

How this scaffold implements each phase of the paper outline (22 Nov 2026).

## Phase 1 - testbed and baseline (weeks 1-4)

| Outline step | Scaffold |
|---|---|
| EVerest SIL with PnC tutorial, Docker | scripts/00, 10 (docker image via EVerest's own builder) or 15 (native), 20 (MQTT + CSMS), 30 (baseline run + trace capture) |
| Network emulation for PLC latency | scripts/60-netem-plc.sh + configs/plc-latency-profiles.json (tc netem; ns-3 not needed at this fidelity, revisit if the freshness evaluation demands per-packet PLC physics) |
| Clean traces of the PnC flow | results/baseline-everest + measurement/capture_traffic.sh (pcapng + OCPP logs + session XML logs) |
| Deliverable: reproducible repo + baseline dataset | this repo; dataset lands in results/ |

## Phase 2 - reproduce the attacks (weeks 5-8)

| Outline step | Scaffold |
|---|---|
| Relay attack, fake charger relays PaymentDetails/Authorization | scripts/40-relay-attack-josev.sh: the attack authors' own published PoC (github.com/securityinmobility/plug-and-charge-relay-poc, fork of the Josev/SwitchEV stack) containerized on one host, two L2 segments (scripts/05-setup-veth.sh) |
| Third EVerest instance as fake charger | adapted: the fake charger must run modified stack code; the published modification is josev-based. docs/everest-patch-points.md gives the C++ port to EvseV2G and scripts/45 is the (experimental) EVerest-as-honest-station variant |
| Certificate-reuse MitM | scripts/50-pki-cert-reuse-mitm.sh (fake station presents the secc2 "compromised station" certificate; configs/secc2LeafCert.cnf fixes a missing file in the upstream PoC) |
| Repeatable test cases + pcaps | measurement/capture_traffic.sh; pcaps + TLS key logs per run |

## Phase 3 - defense design (weeks 9-14)

| Outline step | Scaffold |
|---|---|
| Station binding | defense/README.md part 1 (+ josev patch points; logic verified in measurement/verify_attack_invariant.py) |
| Freshness check | defense/README.md part 2 (bound tuned from the netem matrix) |
| PKI rules | docs/pki-hardening-profile.md |
| Formal model (ProVerif/Tamarin) | not scaffolded - outline marks it optional; the signed-payload definition in defense/README.md is the model's starting point |

## Phase 4 - implementation and measurement (weeks 15-18)

| Outline step | Scaffold |
|---|---|
| Defense as a config-flag patch | DEFENDED env flag in the josev patch (defense/README.md); EVerest manifest flags in docs/everest-patch-points.md |
| Re-run attacks against defended stack | scripts/80-run-experiment-matrix.sh mode=defended x attack topology |
| Cost: latency, bytes, crypto time | docs/measurement-plan.md section 2 (>= 1,000 handshakes, pcap byte deltas, crypto_bench under CPU limits) |

## Phase 5 - generalize, write, submit (weeks 19-26)

The matrix harness doubles as the conformance suite's runner: each attack/
defense case is a script with a pass criterion and captured evidence, in the
style of EmuOCPP. Packaging it for third-party stacks = pointing
scripts/40's honest-side processes at the stack under test.
