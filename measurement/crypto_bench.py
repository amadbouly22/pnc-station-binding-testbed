#!/usr/bin/env python3
"""crypto_bench.py - sign/verify cost of the PnC authorization signature.

ISO 15118-2 uses ECDSA over P-256 (secp256r1/prime256v1) with SHA-256 for the
XML-DSig signature in AuthorizationReq. This benchmarks raw sign and verify
on the exact contract private key the testbed PKI generated, plus the bound
payload the defense adds (challenge || EVSE-ID || station cert fingerprint),
so the paper can report crypto cost in microseconds, separate from EXI/XML
encoding overhead (which the latency matrix measures end to end).

Usage:
  crypto_bench.py --pki PATH/TO/iso15118_2 [--iterations 2000] [--password 12345]
"""
import argparse
import hashlib
import os
import time

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec


def bench(fn, n):
    fn()  # warmup
    t0 = time.perf_counter_ns()
    for _ in range(n):
        fn()
    return (time.perf_counter_ns() - t0) / n / 1000.0  # us


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pki", required=True, help="iso15118_2 dir from create_certs.sh")
    ap.add_argument("--iterations", type=int, default=2000)
    ap.add_argument("--password", default="12345")
    args = ap.parse_args()

    key_path = os.path.join(args.pki, "private_keys", "contractLeaf.key")
    with open(key_path, "rb") as fh:
        key = serialization.load_pem_private_key(fh.read(), password=args.password.encode())
    pub = key.public_key()

    challenge = os.urandom(16)  # GenChallenge is 16 bytes
    evse_id = b"DE*PNX*00001"
    cert_fp = hashlib.sha256(b"station-leaf-cert-der-bytes").digest()
    bound = challenge + evse_id + cert_fp  # the defense's signed payload

    sig = key.sign(challenge, ec.ECDSA(hashes.SHA256()))

    t_sign = bench(lambda: key.sign(challenge, ec.ECDSA(hashes.SHA256())), args.iterations)
    t_verify = bench(lambda: pub.verify(sig, challenge, ec.ECDSA(hashes.SHA256())), args.iterations)
    sig_b = key.sign(bound, ec.ECDSA(hashes.SHA256()))
    t_sign_b = bench(lambda: key.sign(bound, ec.ECDSA(hashes.SHA256())), args.iterations)
    t_verify_b = bench(lambda: pub.verify(sig_b, bound, ec.ECDSA(hashes.SHA256())), args.iterations)

    print(f"ECDSA P-256 / SHA-256, {args.iterations} iterations, this machine")
    print(f"  baseline  sign {t_sign:8.1f} us   verify {t_verify:8.1f} us   (16 B challenge)")
    print(f"  defended  sign {t_sign_b:8.1f} us   verify {t_verify_b:8.1f} us   ({len(bound)} B bound payload)")
    print(f"  defense delta: sign {t_sign_b - t_sign:+.1f} us, verify {t_verify_b - t_verify:+.1f} us")
    print("Note: signed-payload size grows by the EVSE-ID length + 32 B fingerprint;")
    print("EXI/XML overhead of the extra SignedInfo reference is measured by the matrix runs.")


if __name__ == "__main__":
    main()
