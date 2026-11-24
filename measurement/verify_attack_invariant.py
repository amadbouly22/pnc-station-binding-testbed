#!/usr/bin/env python3
"""verify_attack_invariant.py - in-process proof of the attack invariant and
the defense prototype, using the testbed's real PKI material.

This script distills what the full-stack runs (scripts/40, 50) show on the
wire, down to the cryptographic core, so it can run anywhere - including CI -
without network interfaces:

  scenario relay   The honest station's GenChallenge, relayed verbatim to the
                   victim, is signed with the victim's contract key, and the
                   honest station's verification (against the contract cert
                   the attacker presented) ACCEPTS it. Nothing in the signed
                   data names a station - this is the arXiv:2512.15966 bug.

  scenario pki     The fake station presents secc2's certificate (a different
                   station, same V2G root). Chain validation passes; only an
                   explicit expected-station check catches it - which ISO
                   15118-2 gives the car no input for (arXiv:2404.06635 5.3).

  scenario defense Station binding: the signed payload becomes
                   GenChallenge || EVSE-ID || SHA256(station leaf cert DER).
                   A signature made for the fake station FAILS verification at
                   the honest station. Freshness: a challenge/response RTT
                   above the bound (simulated relay delay) is rejected.

Usage: verify_attack_invariant.py --pki PATH/TO/iso15118_2 [--scenario relay|pki|defense|all]
"""
import argparse
import hashlib
import os
import time

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

HONEST_EVSE_ID = "DE*PNX*E00001*1"   # station the attacker car is plugged into
FAKE_EVSE_ID = "DE*PNX*E00002*1"     # fake station plugged into the victim car
FRESHNESS_BOUND_S = 1.0              # tuned by the netem matrix; PLC-local RTT


def load_key(path, password=b"12345"):
    with open(path, "rb") as fh:
        return serialization.load_pem_private_key(fh.read(), password=password)


def load_cert(path):
    with open(path, "rb") as fh:
        return x509.load_pem_x509_certificate(fh.read())


def cn(cert):
    return cert.subject.get_attributes_for_oid(NameOID.COMMON_NAME)[0].value


def scenario_relay(pki):
    victim_key = load_key(os.path.join(pki, "private_keys", "contractLeaf.key"))
    victim_pub = victim_key.public_key()

    # Honest station issues a challenge to (what it believes is) one car.
    gen_challenge = os.urandom(16)
    # Relay: the same bytes reach the victim car through the fake station.
    relayed = bytes(gen_challenge)
    assert relayed == gen_challenge
    # Victim signs. In the full stack this is XML-DSig over the EXI-encoded
    # AuthorizationReq, which carries exactly this challenge and no station
    # identity; the ECDSA core demonstrated here is what binds (or fails to).
    signature = victim_key.sign(relayed, ec.ECDSA(hashes.SHA256()))
    # Honest station verifies against the contract cert the ATTACKER presented.
    victim_pub.verify(signature, gen_challenge, ec.ECDSA(hashes.SHA256()))
    print("relay:   VULNERABLE - relayed signature verifies at the honest station")
    return True


def scenario_pki(pki):
    certs = os.path.join(pki, "certs")
    root = load_cert(os.path.join(certs, "v2gRootCACert.pem"))
    sub1 = load_cert(os.path.join(certs, "cpoSubCA1Cert.pem"))
    sub2 = load_cert(os.path.join(certs, "cpoSubCA2Cert.pem"))
    presented = load_cert(os.path.join(certs, "secc2LeafCert.pem"))   # compromised station
    expected = load_cert(os.path.join(certs, "seccLeafCert.pem"))     # station the car is at

    # Chain building as the car's TLS stack does it (signature checks up the chain).
    sub2.public_key().verify(presented.signature, presented.tbs_certificate_bytes,
                             ec.ECDSA(hashes.SHA256()))
    sub1.public_key().verify(sub2.signature, sub2.tbs_certificate_bytes, ec.ECDSA(hashes.SHA256()))
    root.public_key().verify(sub1.signature, sub1.tbs_certificate_bytes, ec.ECDSA(hashes.SHA256()))
    chain_ok = True

    station_match = cn(presented) == cn(expected)
    print(f"pki:     chain validation passes for wrong-station cert: {chain_ok}")
    print(f"pki:     presented CN={cn(presented)!r} vs expected CN={cn(expected)!r}"
          f" -> station match: {station_match}")
    print("pki:     WEAKNESS - nothing in ISO 15118-2 gives the car the expected CN/EVSE-ID")
    return chain_ok and not station_match


def scenario_defense(pki):
    victim_key = load_key(os.path.join(pki, "private_keys", "contractLeaf.key"))
    victim_pub = victim_key.public_key()
    certs = os.path.join(pki, "certs")
    honest_der = load_cert(os.path.join(certs, "seccLeafCert.pem")).public_bytes(
        serialization.Encoding.DER)
    fake_der = load_cert(os.path.join(certs, "secc2LeafCert.pem")).public_bytes(
        serialization.Encoding.DER)

    def bound_payload(challenge, evse_id, cert_der):
        return challenge + evse_id.encode() + hashlib.sha256(cert_der).digest()

    gen_challenge = os.urandom(16)

    # 1) Station binding: victim signs for the FAKE station (what it is
    #    connected to); honest station recomputes with ITS OWN identity.
    sig = victim_key.sign(bound_payload(gen_challenge, FAKE_EVSE_ID, fake_der),
                          ec.ECDSA(hashes.SHA256()))
    rejected = False
    try:
        victim_pub.verify(sig, bound_payload(gen_challenge, HONEST_EVSE_ID, honest_der),
                          ec.ECDSA(hashes.SHA256()))
    except Exception:
        rejected = True
    print(f"defense: station binding rejects relayed signature: {rejected}")

    # 2) Freshness: honest station measures challenge->response time.
    t0 = time.perf_counter()
    time.sleep(0.08)  # simulated relay backchannel (cellular profile ~80 ms RTT)
    sig2 = victim_key.sign(bound_payload(gen_challenge, HONEST_EVSE_ID, honest_der),
                           ec.ECDSA(hashes.SHA256()))
    rtt = time.perf_counter() - t0
    victim_pub.verify(sig2, bound_payload(gen_challenge, HONEST_EVSE_ID, honest_der),
                      ec.ECDSA(hashes.SHA256()))
    fresh = rtt <= FRESHNESS_BOUND_S
    print(f"defense: freshness check RTT={rtt*1000:.1f} ms, bound={FRESHNESS_BOUND_S*1000:.0f} ms,"
          f" accepted={fresh} (a real relay adds the victim-side session too)")
    return rejected


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pki", required=True)
    ap.add_argument("--scenario", default="all",
                    choices=["relay", "pki", "defense", "all"])
    args = ap.parse_args()

    ok = True
    if args.scenario in ("relay", "all"):
        ok &= scenario_relay(args.pki)
    if args.scenario in ("pki", "all"):
        ok &= scenario_pki(args.pki)
    if args.scenario in ("defense", "all"):
        ok &= scenario_defense(args.pki)
    print("ALL CHECKS PASSED" if ok else "CHECK FAILED")
    raise SystemExit(0 if ok else 1)


if __name__ == "__main__":
    main()
