# Claims and evidence map

Each security claim this repository makes is listed with its implementation, the test case that exercises
it, whether that case **has been executed**, and where the evidence is. A claim without an executed,
passing case is shown as such. Wording in talks or slides should not go beyond the "Claim" column.

## Last recorded run

| Field | Value |
|---|---|
| Run id | `20261102T203430Z` (`evidence/runs/20261102T203430Z/`, **local, gitignored — not in the repository**) |
| Procedure | clean room: `make lab-down` → `make lab-up` → `make deploy` → `make send-telemetry` → `make test` |
| Date / operator machine | 2026-11-02, one macOS arm64 laptop, Docker Desktop 29.6.1 (7.75 GiB VM) |
| Commit | `6b1e71745c486b6ed528b30699f010fca7916def` **with uncommitted changes** (`working_tree_dirty: true` in `meta.json`). The results therefore describe the working tree at that time, not any commit. **Re-run on the release commit before citing** ([release checklist](RELEASE-CHECKLIST.md)). |
| Versions | Kubernetes v1.34.0, Cilium 1.19.10, cert-manager v1.20.4, Collector 0.163.2, telemetrygen v0.163.0 |
| Result | **33 PASS, 0 FAIL, 2 NOT RUN** (both NOT RUN are documented known gaps, listed below). `make test` exit code 0. |
| Timings observed | `lab-up` 114 s, `deploy` 14 s, `send-telemetry` 9 s, `test` 420 s |

Status vocabulary: **PASS** = executed and matched, including positive controls · **FAIL** · **NOT RUN** =
not executed (never counted as success). "Executed in lab" means the lab described in
[`lab/README.md`](../lab/README.md) only; nothing here has been run against any other cluster, CNI, OS or
Collector version.

## Claims

| ID | Claim (property) | Implementation | Test case(s) | Status |
|---|---|---|---|---|
| K1 | Telemetry from an approved source with a valid client certificate reaches the backend through the gateway (end to end) | `manifests/`, `lab/backend`, `lab/traffic-generator` | D1, R1, E1, ROT0 | PASS |
| K2 | The gateway **requires** a client certificate (PA) | receiver `tls.client_ca_file` in `manifests/00-foundation.yaml` | R2 | PASS |
| K3 | The gateway rejects a client certificate that does not chain to the trusted CA, even when the issuer name is spoofed (PA) | same | R3 | PASS |
| K4 | A client rejects a gateway certificate not issued by its trusted CA, and one whose SANs don't cover the dialed name (PA/TP) | client `--ca-cert`, server SANs in `01-certificates.yaml` | R4, R5 | PASS |
| K5 | The backend **requires** a client certificate and rejects an untrusted one (PA) | `lab/backend/backend.yaml` receiver `client_ca_file` | E4, E5 | PASS |
| K6 | An exporter configured like the gateway's rejects a backend with an untrusted CA or a name not in its SANs (PA/TP) | exporter `tls.ca_file` | E2, E3 | PASS — *via a probe Collector mirroring the gateway's exporter TLS settings; the live gateway is not modified (R7)* |
| K7 | Connections to the backend negotiate TLS ≥ 1.2 (TP) | Collector defaults | E6 (observed `TLSv1.3`, `TLS_AES_128_GCM_SHA256`) | PASS — observed for the witness's connection |
| K8 | A pod outside the approved namespace/label set cannot reach the gateway (AZ, network) | gateway ingress policy | N2, N3 | PASS |
| K9 | Hubble recorded DROPPED flows for those denied attempts | Cilium/Hubble | N2h, N3h, N4h | PASS — *observational corroboration only; not proof of TLS authentication or kernel isolation* |
| K10 | An approved source cannot bypass the gateway to reach the backend (AZ, network) | `otel-backend-allow` | N4 | PASS |
| K11 | An approved source's egress is limited to the gateway and DNS | `lab/traffic-generator` `exporter-egress` | N5 | PASS (tested against the kube-apiserver ClusterIP only) |
| K12 | A **valid** client certificate used from an unauthorized namespace is stopped by the network layer, and the failure is distinguishable from a TLS rejection | NetworkPolicy + test classifier | N6 | PASS |
| K13 | After forced reissuance with `rotationPolicy: Always`, cert-manager produces a new certificate with a new key, and each gateway pod starts **serving** it on new connections | cert-manager, Collector `reload_interval: 1m` | ROT1, ROT2 | PASS — new cert observed on one pod and the Service ≈ 55–60 s and on the other pod ≈ 120 s after the trigger (3 runs: 54/121, 56/123, 122/56 s); the replicas **disagreed for roughly a minute** |
| K14 | A new client connection after rotation completes end to end | same | ROT3 | PASS |
| K15 | **Observed in one 240 s run:** no lost records on a long-lived connection (1202 sent, 1202 delivered) and no failed fresh handshakes (324 OK, 0 failed) across rotation | same | ROT4 | PASS as a measurement. **This is not a zero-downtime guarantee**: single run, one replica count, one reload interval, no CA change, TLS certificates only consulted at handshake time |
| K16 | The gateway's **exporter** picks up its rotated client certificate | `reload_interval` on exporter TLS | ROT5 | **NOT RUN (known gap)** — the backend does not record peer identity, so delivery cannot distinguish old from new certificate. **Unverified.** |
| K17 | CA rotation with trust-bundle overlap works | — | ROT6 | **NOT RUN (known gap)** — not implemented |
| K18 | An authenticated producer's attacker-authored instruction text is accepted and stored (limitation, TT) | — | S1 | PASS (demonstrates the *absence* of content protection) |
| K19 | In a deterministic simulation, a mutating action derived from that text is proposed, **denied** by a separate default-deny policy with a recorded reason, and never (simulated-)executed; the read-only proposal is allowed (AA) | `scenarios/poisoned-log/` | S2–S7 | PASS — simulation only; the consumer is **not** an LLM (R10). S7 shows the check fails for a broken allow-all policy |
| K20 | Hash-chain log + HMAC checkpoint detects modification, deletion, reordering, truncation past the checkpoint, and full re-hash (SI, detection only) | `examples/tamper-evident/` | `test_chainlog.py` (10 unit tests) | PASS — executed locally 2026-11-02, standalone, **not integrated with the lab backend**; does not provide append-only enforcement; unanchored-tail truncation is a documented non-detection |
| K21 | Gateway and backend Collector configs are valid for the pinned Collector version | `lab/scripts/validate-collector-config.sh` | static (`otelcol validate`; keys/components only, not runtime behaviour) | PASS — script executed locally. CI workflow **never run on GitHub** |
| K22 | Rendered manifests are schema-valid (kubeconform + cert-manager CRDs); ShellCheck and yamllint report no findings | `.github/workflows/ci.yml`, `make check` | static | PASS — the equivalent commands were run individually (ShellCheck 0.10.0 and kubeconform 0.7.0 via Docker, yamllint 1.37.1 via a throw-away venv). `make check` itself was **not** run (ShellCheck/yamllint are not installed on the author's machine) and the CI workflow has **never run on GitHub** |

## Things this repository does **not** claim

* Zero-downtime rotation, production readiness, audit/certification, or battle-testing.
* That mTLS makes telemetry **truthful** (K18) or that Hubble proves authentication or isolation (K9).
* Any result for Prometheus federation authentication, Loki/Grafana tenant isolation, WORM/append-only
  storage, Falco/Kubernetes-audit detection, tail-sampling manipulation (T1), or the exporter-pivot (T2). **None
  of these is implemented or tested.**
* Identity-level authorization: all certificates share one CA; the backend does not check *which* client
  connected (residual risk R2 in the [worked threat model](../threat-model/WORKED-EXAMPLE.md)).
* Behaviour of any real LLM/agent.
* Any platform other than macOS/arm64 + Docker Desktop; the GitHub Actions `integration` job is unverified.

## How to reproduce a claim

```bash
make lab-up deploy test            # all lab cases; evidence in evidence/runs/<ts>/
TESTS=test_receiver_mtls.sh make test   # one group (TESTS is read by tests/run-all.sh)
python3 -I examples/tamper-evident/test_chainlog.py
make check                         # static (needs shellcheck, yamllint, docker, kubectl)
```

Evidence handling, sanitization and retention: [`evidence/README.md`](../evidence/README.md).
