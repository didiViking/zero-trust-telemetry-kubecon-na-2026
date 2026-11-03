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
| `test_network_isolation.sh` | N1–N6 (+ N2h/N3h/N4h) | Unauthorized sources, gateway bypass, and non-allow-listed egress are blocked; a *valid* cert from the wrong place fails at the network layer | busybox TCP probes by ClusterIP + Hubble DROPPED corroboration |
| `test_certificate_rotation.sh` | ROT0–ROT6 | A new cert/key is actually served after reissuance; delivery behaviour during the window is measured | long-lived sender + fresh-connection prober, see below. ~5 min |
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
* **Not covered (recorded NOT RUN, with reasons):** exporter (gateway→backend) client-cert reload (ROT5: the
  backend does not log peer identity, so success cannot distinguish old from new cert), CA rotation with trust
  overlap (ROT6: not implemented).

## Mutation check (manual)

To convince yourself a test can fail, break the control it covers on a throw-away lab and re-run it, e.g.
delete `client_ca_file` from `lab/backend/backend.yaml`'s receiver and `make deploy`: `E4`/`E5` must FAIL.
(The scenario test contains an automated version of this idea: S7.) This was **not** executed as part of the
initial validation.
