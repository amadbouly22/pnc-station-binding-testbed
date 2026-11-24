# PKI hardening profile

Turns the CCS measurement study's sketch (arXiv:2404.06635, section 5.3) into
issuance rules, and defines how the testbed quantifies the improvement.

## The flaw

Charger TLS certificates carry the EVSE-ID, but the car cannot check it: it
does not know which station it is plugged into. One stolen charger
certificate (extracted from a charger in the field, or supply-chain)
therefore lets an attacker man-in-the-middle every TLS session under the same
root CA, network-wide, until expiry or revocation. In the testbed: the fake
station presents `secc2LeafCert.pem` (CN SECCCert2) to a car plugged into
station SECCCert; chain validation passes (scripts/50-pki-cert-reuse-mitm.sh,
and verified in-process by `measurement/verify_attack_invariant.py --scenario pki`).

## Issuance rules (the profile)

1. **One certificate per EVSE-ID.** The leaf CN is exactly the EVSE-ID
   (DIN 70121 / ISO 15118 format, e.g. `DE*PNX*E00001*1`). CAs refuse reuse
   and re-issuance to a different requester without operator proof.
2. **Location binding.** Installation GPS coordinates go into the certificate
   (Subject Locality attribute, as the measurement study proposes; it is
   unused today). CAs require proof of installation location at issuance.
3. **Short validity + automated renewal.** Leaf validity in weeks, not years,
   renewed over the charger's existing OCPP channel, shrinking the window a
   stolen certificate is useful.
4. **Revocation that works offline.** Cars cache CRLs/OCSP staples per root;
   sessions proceed with a soft-fail flag when data is stale beyond a
   configured age (logged, for the paper's deployability analysis).

## Car-side check (what the patch enforces)

After the TLS handshake, the car compares the presented leaf's EVSE-ID with
the session's expected EVSE-ID (from SessionSetupRes / the operator's
announcement) and, when the car has GNSS, its own position against the
certificate's Locality. Mismatch: abort before any payment message. The
defense's station binding (defense/README.md part 1) makes the same identity
cryptographically authoritative for payment, so a MitM cannot downgrade the
check away.

## Quantifying the improvement (for the evaluation section)

- Impersonation surface = number of stations a single compromised certificate
  can impersonate. Baseline: every station under the root (325 chargers in
  the measurement study's sample; one Hubject root for all European PnC
  networks). With rules 1+2: exactly 1 station, plus detection at the first
  mismatched session.
- The matrix harness (scripts/80) runs the MitM scenario against defended
  mode; success = session aborted before PaymentDetails, counted in
  `summary.csv` (`completed=0` with an abort marker in the EVCC log).
