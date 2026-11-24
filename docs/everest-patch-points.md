# EVerest patch points

Grounded in the EVerest monorepo (github.com/EVerest/EVerest, main branch,
manual 2026.10.0-rc3, inspected 2026-11-22).

## Charger side (honest station): modules/EVSE/EvseV2G/iso_server.cpp

- **PaymentDetailsReq handling, ~line 1177-1330.** Parses the contract
  certificate chain (`parse_contract_certificate`, line ~1189), stores the
  chain, generates the 16-byte GenChallenge with `generate_random_data`
  (line ~1316) and stashes it in `conn->ctx->session.gen_challenge`
  (line ~1333).
  - *Freshness patch:* record `std::chrono::steady_clock::now()` next to the
    gen_challenge store.
- **AuthorizationReq handling, ~line 1377 onwards.** Receives the signature
  and hands verification to the `evse_security` interface
  (`publish_iso_authorization_req`, line ~367, forwards Id/GenChallenge).
  - *Station-binding patch:* extend the verified content with the session's
    EVSE-ID and own leaf-cert hash before/inside the security-module verify
    call; reject on mismatch.
  - *Freshness patch:* compare elapsed time against a configured bound
    (`EvseV2G` manifest gains `pnc_freshness_bound_ms`, default disabled) and
    stop the session with a failed AuthorizationRes when exceeded.
- Config flag: add both to `modules/EVSE/EvseV2G/manifest.yaml` so baseline
  and defended modes share one binary.

## EV side: modules/EV/Ev15118 (C++, built on lib/iso15118's ev::Controller)

- The EV builds and signs AuthorizationReq inside libiso15118
  (`lib/iso15118` in the monorepo). The binding patch adds the two signed
  elements where the AuthorizationReq signature is assembled; the EV knows
  the station identity from the TLS peer certificate.
- Older EVerest releases (up to 2025.x) shipped `modules/EV/PyEvJosev`, the
  Josev-based EV module; on those releases the josev defense patch
  (defense/README.md) applies almost verbatim inside EVerest. Current main
  uses the C++ Ev15118 instead.

## Crossing the SIL boundary (why the fake charger is josev-based)

The relay attack needs two attacker-controlled endpoints running *modified*
code. EVerest's SIL simulates control pilot and SLAC *inside* one process
pair (YetiSimulator + SlacSimulator + EvManager); only HLC (SDP, TCP, TLS,
V2G) goes over a real interface. An external stack therefore cannot simply
replace one side of an EVerest SIL pair:

- **Charger-only instance facing an external car:** possible in principle
  (configs/everest/config-honest-charger.yaml) but the simulated CP must be
  driven to "plugged in" via MQTT or a stub EvManager; see the config's
  KNOWN LIMITATION note. UNVERIFIED - the integration harness is
  scripts/45-relay-attack-everest.sh.
- **Fake charger:** must run modified stack code regardless of framework.
  The paper's authors did this in Josev (the stack EVerest itself used for
  EV-side simulation until Ev15118). scripts/40-relay-attack-josev.sh is the
  working reproduction; porting the fake charger to a patched EvseV2G build
  is a C++ exercise over the same patch points above.

The paper should state this adaptation explicitly: the honest-station and
victim-car roles run unmodified, industry-grade stacks; the attacker roles
run the published PoC modifications.
