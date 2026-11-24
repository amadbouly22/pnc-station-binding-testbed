# Defense design and prototype

Three parts, matching the paper outline. The reference implementation is a
patch to the Josev stack (the same stack the attack PoC modifies), so the same
testbed runs baseline, attack, and defended modes. The EVerest port uses the
patch points in `docs/everest-patch-points.md`.

The patch is `defense/josev-defense.patch` against upstream josev
(EcoG-io/iso15118) commit 676b315 (v0.28.3). Apply or revert it with:

```bash
defense/apply-defense.sh                # patch ~/pnc-relay/honest + venv-honest
defense/apply-defense.sh --revert       # back to pristine 676b315
```

Everything the patch does is gated on the `DEFENDED` environment variable
(any value except empty/0/false/no/off enables it), so once applied, the same
honest stack serves baseline and defended runs: `scripts/80` exports
`DEFENDED=0`/`DEFENDED=1` per run, and for the attack topology
`DEFENDED=1 scripts/40-relay-attack-josev.sh` runs the honest station and the
victim car in defended mode against the unpatched PoC sides.

## 1. Station-identity binding (blocks the relay attack)

**Bug (arXiv:2512.15966):** the AuthorizationReq signature covers the
GenChallenge and nothing else. A signature made for station A verifies at
station B.

**Fix:** the EVCC adds one extra `Reference` to the XML-DSig `SignedInfo` of
its AuthorizationReq whose digest covers

    EVSE-ID || SHA-256(station TLS leaf certificate, DER)

- The car learns both halves from the session it is actually in: the EVSE-ID
  from SessionSetupRes, the certificate from the TLS handshake
  (`writer.get_extra_info("ssl_object").getpeercert(binary_form=True)`). No
  extra message, no schema change: the binding value is not a message
  element, only its digest enters SignedInfo. (This is exactly the mitigation
  the attack paper sketches in its section 5; we implement and measure it.)
- The station adds the same Reference id (`#stationBinding`) to the elements
  it verifies, recomputed with its OWN EVSE-ID
  (`evse_controller.get_evse_id(ISO_15118_2)`) and its OWN leaf certificate
  (`CertPath.SECC_LEAF_DER`). A signature relayed from the victim's session
  with the fake station binds the fake station's EVSE-ID and `secc2LeafCert`
  and fails the digest comparison at the honest station. Stripping the extra
  Reference breaks the SignatureValue itself, so the attacker cannot remove
  the binding either.
- Backward compatibility, verified at the signature level: a baseline SECC
  ignores the extra Reference (it only checks the elements it knows), so a
  defended car still charges at an unpatched station. The defended SECC
  fails closed: a baseline car that sends no binding is rejected.

**Josev patch points** (upstream josev, commit 676b315 / v0.28.3):

- New module `iso15118/shared/defense.py`: env flags, TLS peer-certificate
  extraction, binding-value construction. All defense code paths flow
  through it.
- Car side: `iso15118/evcc/states/iso15118_2_states.py`, class
  `PaymentDetails`, where `create_signature(...)` is called for the
  AuthorizationReq: appends the `(stationBinding, binding)` element.
- Station side: `iso15118/secc/states/iso15118_2_states.py`, class
  `Authorization`, where `verify_signature(...)` is called: appends the
  recomputed binding element.
- Config flag: env var `DEFENDED` (read by `iso15118/shared/defense.py`).

## 2. Station pinning (blocks wrong-station certificates)

From `docs/pki-hardening-profile.md`: charger TLS certificates chain to the
same V2G root, so chain validation alone accepts ANY station's certificate.
With the pinning input, the car aborts the session before signing anything
when the connected station is not the expected one.

- Input: env var `EXPECTED_SECC_ID` (the operator-announced station
  identity). Compared against the presented TLS leaf certificate's CN and
  against the session's EVSE-ID; a match on either accepts. Unset: no
  check, identical to baseline. In the testbed PKI the honest station's CN
  is `SECCCert`, the compromised one `SECCCert2`.
- Patch point: same EVCC `PaymentDetails` state, before `create_signature`.
  Mismatch -> `stop_state_machine(...)`, session aborted before the car
  signs or pays. `scripts/80`'s `summary.csv` shows this as `completed=0`
  with the pinning failure in `evcc.log`.

## 3. Freshness check (defense in depth, catches loose bindings)

The SECC records `time.monotonic()` when it builds PaymentDetailsRes (SECC
`PaymentDetails` state) and rejects the first AuthorizationReq arriving
later than `FRESHNESS_BOUND_S` seconds (default 2.0, inside ISO 15118-2's
own 2 s response timeout for this message) with
`FAILED_CHALLENGE_INVALID`. The bound is NOT hardcoded doctrine: it is
tuned per deployment from measured PLC latency (netem profiles in
`configs/plc-latency-profiles.json`) and the matrix reports false-reject
rates per profile. Station binding alone already blocks the billing attack;
the freshness check is the second signal and the paper says so, per the
outline's risk section.

## Validation performed (2026-11-22, against the real code at 676b315)

- `measurement/verify_attack_invariant.py --scenario all` against a freshly
  generated test PKI: relay succeeds unprotected, wrong-station cert passes
  chain validation, station binding rejects the relayed signature.
- The patch's binding construction was exercised through the REAL josev
  `create_signature`/`verify_signature` and the real EXI codec with the
  real contract key and station certificates:
  1. defended car + defended honest station: signature verifies;
  2. signature bound to the fake station (`secc2LeafCert`): digest mismatch
     on `#stationBinding`, rejected at the honest station;
  3. defended car + baseline station: verifies (extra Reference ignored);
  4. baseline car + defended station: rejected (fail closed).
- The defended-pair full handshake and the defended-attack run are executed
  by the matrix: `sudo scripts/80-run-experiment-matrix.sh --modes
  baseline,defended` (direct pair) and `DEFENDED=1
  scripts/40-relay-attack-josev.sh` (attack must not reach
  ChargeParameterDiscovery on the attacker side).

## Limits (state these in the paper)

- Station binding defeats the relay only while the fake and honest stations
  differ in EVSE-ID or leaf certificate. One stolen certificate presented
  under its own EVSE-ID (the cert-reuse attack) still passes the binding;
  that is what station pinning and the PKI hardening profile
  (`docs/pki-hardening-profile.md`) address.
- Pinning needs a trustworthy expected-station input (operator announcement
  over OCPP, QR code, ...). The patch provides the check; the announcement
  channel is out of scope.
- The freshness bound trades off against PLC latency spikes; false-reject
  rates per netem profile come out of the `scripts/80` matrix.
- The extra Reference is ignored by unpatched peers, so a mixed fleet works,
  but protection only exists when BOTH sides are defended.
