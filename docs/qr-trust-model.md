# QR Trust Model

## What is signed
- `PairingQrPayload` is canonicalized as newline-delimited fields in a fixed order.
- `signature_b64` is blanked during canonicalization before verification.
- Signature algorithm for M2.6 is `rsa-pkcs1-sha256`.

## Who signs it
- The Provinode Room desktop TLS leaf certificate private key signs the QR payload.
- The QR payload includes `desktop_cert_fingerprint_sha256` so the scanner knows which TLS leaf it must trust for verification.

## How Scan verifies it
1. Decode and validate QR JSON shape.
2. Enforce `https` pairing endpoint, expiry, wire version, fingerprint format, and QUIC endpoint format.
3. Open a pinned HTTPS connection to the advertised Room endpoint.
4. Fetch `GET /pairing/identity`.
5. Confirm the live leaf fingerprint matches `desktop_cert_fingerprint_sha256`.
6. Verify `signature_b64` over the canonical payload with the live leaf public key.
7. Only then import the pairing settings into the Scan UI state.

## Failure modes
- malformed QR
- expired QR
- invalid signature encoding
- invalid signature
- signer untrusted / fingerprint mismatch
- signer verification unreachable

## Scope
- This is local-first trust bootstrap for M2.6.
- It does not introduce a cloud trust root.
- Long-term trust still comes from the paired desktop identity persisted after successful confirmation.
