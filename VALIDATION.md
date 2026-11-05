# Validation Plan (not a test report)

**Status:** the rows marked *automated* below are implemented as executable tests under [`tests/`](tests/README.md)
and run against the disposable lab (`make lab-up deploy test`). Their outcomes are recorded per case in
`evidence/runs/<timestamp>/results.json` and summarised, with execution status, in
[`docs/claims-and-evidence.md`](docs/claims-and-evidence.md). Rows marked *manual* or *not implemented* remain
**NOT RUN**. This file is still a plan, not a report: attach real evidence from **your** environment before
claiming that a control works there; lab results do not transfer to a different cluster, CNI or Collector version.

| Control | Suggested staging test | Expected observation | Evidence to retain | Executable test |
|---|---|---|---|---|
| Manifest preflight | Validate YAML schema and Collector config with the **chosen** Collector release | No validation errors | tool versions and command output | *manual*: `otelcol validate` was run by hand against 0.136.0 and 0.163.2 during lab build; no CI yet |
| PKI issuance | Inspect `Certificate`, Secret and issuer status | Issued certificate with expected SANs and key usages | sanitized `kubectl describe certificate`, certificate metadata (never private key) | partly: certificates reach `Ready` in `lab/deploy.sh`; SAN/key-usage inspection is *manual* |
| Receiver mTLS | Connect with valid trusted client certificate; then untrusted/no client certificate | Trusted connection accepted; untrusted handshake rejected | sanitized client/server logs | *automated*: `test_receiver_mtls.sh` R1–R5 |
| Exporter mTLS | Verify backend server SAN/CA and required client certificate | Valid identity succeeds; invalid CA/name fails | sanitized handshake results | *automated*: `test_exporter_mtls.sh` E1–E5 (probe Collector mirrors gateway TLS settings) |
| Key rotation | Trigger controlled reissuance in staging and compare public-key fingerprints | New key after reissuance under `rotationPolicy: Always` | timestamps, public-key fingerprints (not secrets) | *automated*: `test_certificate_rotation.sh` ROT1 |
| Availability during rotation | Generate continuous OTLP traffic while reissuing; check Collector reload or rolling restart | No unplanned ingestion gap **if** reload, trust overlap and availability are correctly configured | time-series of accepted/exported items and error counts | *automated measurement*: `test_certificate_rotation.sh` ROT2–ROT4 and `test_ca_rotation.sh` CAR0–CAR5 (CA overlap, exporter pickup); single runs |
| Network isolation | Generate one allowed and one denied OTLP connection | Intended forwarded and dropped datapath events | Hubble flows, policy snapshot, pod labels | *automated*: `test_network_isolation.sh` N1–N6 |
| DNS/backend egress | Verify gateway can resolve backend and reach only approved destinations | Required flow succeeds; unauthorized egress blocked | Hubble flows and application logs | partly: N5 (egress allow-list) and N1 (DNS+connect); DNS-specific policy is not separately tested |
| Runtime detection (optional) | Install and tune explicit Falco rules and audit plugin in separate lab | Expected controlled test events raise alerts | rule version and sanitized alert output | *not implemented* (no Falco in the lab) |
| Threat model | Walk through T1–T5 with owners and residual risks | Reviewed decisions and follow-up actions | signed-off worksheet | *manual*: see `threat-model/WORKED-EXAMPLE.md` (draft, unsigned) |

## Evidence record template

- Cluster type / CNI / versions:
- Kubernetes namespace and test workload labels:
- Collector version and exact config revision:
- cert-manager version and issuer configuration reference:
- Hubble/Cilium versions:
- Test date/time and operator:
- Test performed / expected result / actual result:
- Evidence location:
- Outcome: PASS / FAIL / NOT RUN
- Limitations and remediation owner:

## Safety and accuracy

- Run disruptive tests only in an isolated test environment.
- Do not publish certificates' private keys, bearer tokens, log credentials, or sensitive telemetry as evidence.
- Network-level `FORWARDED`/`DROPPED` observations are not substitutes for TLS authentication tests.
- A rotation claim of **zero downtime** needs measured continuity during the rotation window; do not infer it from cert-manager issuance alone.
