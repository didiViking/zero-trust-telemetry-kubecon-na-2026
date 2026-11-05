# Executable security tests

Run against the lab (`make lab-up deploy`) with `make test` (or `tests/run-all.sh`). Select tests with
`TESTS="test_receiver_mtls.sh test_exporter_mtls.sh" tests/run-all.sh`. Each script also runs standalone.
Evidence goes to `evidence/runs/<timestamp>/` — see [evidence/README.md](../evidence/README.md).

**Exit codes:** `0` all PASS · `1` any FAIL · `3` no FAIL but at least one NOT RUN · `2` prerequisite missing.
A case that could not run is **never** counted as passed.

| Script | Cases | What it establishes | Method |
|---|---|---|---|
| `test_telemetry_delivery.sh` | D1 | Valid cert + approved source ⇒ traces, metrics, logs reach the backend | telemetrygen Job; marker found in backend file |
| `test_receiver_mtls.sh` | R1–R5 | Gateway **requires** a client cert and rejects an untrusted one; client rejects an untrusted gateway CA and a name not in the SANs | same sender pod spec each time; only the TLS credential/CA/name changes |
| `test_exporter_mtls.sh` | E1–E5 | Gateway-style exporter rejects a backend with untrusted CA or wrong name; backend rejects no / untrusted client cert | throw-away probe Collector with the gateway's exporter TLS settings, plus an `openssl s_client` witness for the no-cert case |
| `test_network_isolation.sh` | N1–N6, N4b (+ Hubble corroboration N2h/N3h/N4h/N4bh) | Unauthorized sources, gateway bypass, and non-allow-listed egress are blocked; a *valid* cert from the wrong place fails at the network layer | busybox TCP probes by ClusterIP + Hubble DROPPED corroboration |
| `test_certificate_rotation.sh` | ROT0–ROT4 | A new cert/key is actually served after reissuance; delivery behaviour during the window is measured | long-lived sender + fresh-connection prober, see below. ~5 min |
| `test_ca_rotation.sh` | CAR0–CAR5 | CA rotation with trust overlap under traffic; the gateway **exporter** presents the rotated certificate | backend is made to trust only a new CA B (control: it first rejects the old cert); everything temporary is restored and re-verified. ~4 min |
| `mutation-check.sh` (`make mutation-check`, not in `make test`) | M1–M5 | The tests above go red when the control they cover is deliberately broken | breaks one control at a time in the lab, restores, re-verifies. ~6 min |
| `../scenarios/poisoned-log/test.sh` | S1–S7 | Poisoned-but-authenticated telemetry → proposed unsafe action → denied before (simulated) execution | see its README |

## Design rules the tests follow

1. **Positive control first.** Every negative group runs the same path with valid credentials first. If that
   fails, the negatives are recorded `NOT RUN` ("uninterpretable"), not PASS.
2. **One variable at a time.** Negative cases reuse the positive control's pod spec and change only the
   credential, trusted CA, or dialed name.
3. **Failure classification** (`classify_failure` in `lib/harness.sh`) separates `TLS_CLIENT_CERT_REQUIRED`,
   `TLS_CLIENT_CERT_REJECTED`, `TLS_SERVER_CERT_UNTRUSTED`, `TLS_SERVER_NAME_MISMATCH`, `DNS_FAILURE`,
   `CONN_REFUSED`, `PEER_RESET`, `NETWORK_TIMEOUT`. A case passes only on the *specific* expected class
   **and** absence of the run marker at the backend. A `NETWORK_TIMEOUT` is never accepted as an mTLS
   rejection (case N6 asserts the converse).
4. **Application-level evidence plus Hubble.** Hubble DROPPED flows are recorded as separate `…h` cases; they
   corroborate, they do not stand in for the connect/handshake result.
5. **Bounded waits, no blind sleeps.** Polling loops have explicit upper bounds.
6. **Cleanup always runs.** Test-created objects carry `zt-lab/test=true`; an `EXIT` trap and a pre-test sweep
   delete only those. No test edits the live gateway/backend Deployments, ConfigMaps or NetworkPolicies.
   Exporter tests add two *temporary* NetworkPolicies (labelled) and remove them.

## Notes on specific results

* **Why the rogue CA reuses the lab CA's subject name (R3, E5).** A TLS server advertises the DNs of CAs it
  accepts; Go clients silently *decline to send* a certificate that cannot chain to one. With a differently
  named rogue CA the gateway reported "certificate required" (the cert was never presented). Matching the DN
  makes the client present the rogue cert, so it is the server's signature check that rejects it.
* **E4 uses a witness.** The Collector exporter without a client cert sometimes sees `connection reset by
  peer` instead of the TLS alert (it races the server closing). A reset is ambiguous alone, so E4 also requires
  an `openssl s_client` witness to observe the explicit `certificate required` alert after verifying the
  backend certificate.
* **Rotation (ROT\*).** TLS certificates are consulted only at handshake time. The *long-lived* sender holds
  one connection for the window (so says nothing about the new cert; it shows survivability), while the
  *fresh-connection* prober opens a new connection every ~2 s to the Service and to each gateway pod IP and
  records the served certificate fingerprint. Reissuance is triggered via the cert-manager `Issuing`
  condition (what `cmctl renew` does). `ROT4` reports what happened in that run (records lost, failed fresh
  handshakes). **It is a measurement from a single run, not a zero-downtime guarantee.**
* **Exporter certificate pickup (CAR4).** The backend cannot log peer identity, so this is shown indirectly:
  after the gateway certificate is re-issued from CA B, the backend is made to trust *only* B and restarted
  (forcing the exporter to reconnect). CAR0 first proves the backend really rejects the old A-issued
  certificate; delivery succeeding afterwards means the exporter presented a B-issued one.
* **Not covered:** revocation, intermediate CAs, the Collector exporter's behaviour on other versions, and
  rotation of the *client* (producer) certificates.

## Mutation check

`make mutation-check` breaks one control at a time in the lab and requires the covering test to go red while
its positive control stays green. A mutation that goes undetected is reported as FAIL (the test is blind).

| Mutation | Must FAIL | Must still PASS |
|---|---|---|
| M1 backend stops requiring client certs | E4, E5 | E1–E3 |
| M2 gateway stops requiring client certs | R2, R3 | R1, R4, R5 |
| M3 gateway ingress policy opened | N2, N6 | N1, N3, N4, N4b, N5 |
| M4 backend ingress policy opened | N4b | N1–N4 |
| M5 approved-source egress allow-list opened | N5 | N1–N4 |

N3 and N4 intentionally stay green under M3/M4: they are blocked by *two* layers (source-side policy and
destination policy), so opening one layer changes nothing. The first mutation run showed exactly this and
led to adding **N4b**, which uses a source with open egress to isolate the backend's ingress policy. The
scenario test's S7 is an automated mutation check of the authorizer. Mutations are limited to configuration
the lab owns; they do not test the Collector's TLS implementation.
