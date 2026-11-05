# Local mTLS lab

**New to this? Start with [GETTING-STARTED.md](GETTING-STARTED.md)** (`make doctor && make quickstart`).

A disposable **kind + Cilium/Hubble + cert-manager** cluster that supplies everything the blueprints in
`manifests/` say they do *not* provide: a CA, a trust bundle, an OTLP backend that requires client
certificates, and a synthetic-telemetry client. From a clean checkout you can start it, send telemetry
over mTLS, and prove the backend received it.

> **Lab only.** The PKI shortcuts, single shared CA, and permissive-by-design test tooling here are for
> learning. See [pki/README.md](pki/README.md) and [Limitations](#limitations).

## Prerequisites

| Tool | Version used when this lab was exercised | Notes |
|---|---|---|
| Docker | 29.6.1 (Docker Desktop, macOS arm64) | daemon must be running; allocate **≥ 6 GiB** to Docker (see resources) |
| kind | 0.30.0 (`bootstrap.sh` requires ≥ 0.30.0) | |
| kubectl | 1.34.2 | must also provide `kubectl kustomize` (built in) |
| Helm | 4.0.1 | charts are fetched with `--repo`; your global Helm repo list is not modified |
| openssl, jq, base64, git | system versions | used by scripts and tests |
| Network access | — | pulls charts and images from `helm.cilium.io`, `charts.jetstack.io`, `quay.io`, `docker.io`, `ghcr.io` |

Only macOS (Apple silicon) has been exercised. Scripts avoid bash-4-only features so Linux should work,
but **that is untested**. All scripts need bash; they are not POSIX `sh`.

### Pinned versions (`versions.env`)

Kubernetes v1.34.0 (kind node image pinned by digest) · Cilium 1.19.10 (Cilium's docs list Kubernetes
1.32–1.35 as e2e-tested for the 1.19 line) · cert-manager v1.20.4 · OpenTelemetry Collector contrib
0.163.2 · telemetrygen v0.163.0 · busybox 1.37.0 · alpine/openssl 3.5.4. "Pinned" means *exercised together
here*, not a compatibility guarantee elsewhere.

## Quick start

```bash
make lab-up          # cluster + Cilium/Hubble + cert-manager + lab PKI      (~2 min observed, see below)
make deploy          # gateway (manifests/), backend, client namespace
make send-telemetry  # synthetic traces/metrics/logs over mTLS, then backend-receipt proof
make test            # executable security tests -> evidence/runs/<timestamp>/
make lab-down        # delete ONLY this lab's cluster and lab/.kube, lab/.work
```

Expected `make send-telemetry` output (run id differs):

```
[..] sending synthetic telemetry run_id=run-20261102T195703Z-b23578 via otel-gateway.telemetry-secure.svc.cluster.local (mTLS client cert: traffic-generator-tls)
[..] PASS  backend received traces (1 batch(es))
[..] PASS  backend received metrics (1 batch(es))
[..] PASS  backend received logs (1 batch(es))
[..] backend receipt proven for run_id=run-20261102T195703Z-b23578
```

Receipt is proven at the **application level**: the sender stamps a unique `lab.run_id` into every record
and the script finds that marker in the backend's received-telemetry file. The sender exiting 0 alone is
never treated as proof.

## What is deployed

```
telemetry-clients ns (label telemetry-client=true)          telemetry-secure ns (default-deny)
  telemetrygen Job ──mTLS (client cert: traffic-generator)──▶ otel-gateway ×2 ──mTLS (client cert: otel-gateway)──▶ otel-backend
  pod label telemetry-exporter=true                           from manifests/                                        requires client certs;
                                                                                                                      writes /data/otlp.jsonl
cert-manager ns: lab-root-ca ──▶ ClusterIssuer telemetry-ca ──▶ leaf certificates (ECDSA P-256)
telemetry-untrusted ns: no policies, no access label — used by tests as the "unauthorized source"
```

| Component | Source | Notes |
|---|---|---|
| Gateway (Deployment, ConfigMap, Service, Certificate, NetworkPolicies) | `manifests/` — **reused unchanged by the overlay** | see [Changes to the blueprint](#changes-to-the-blueprint) |
| Backend | `lab/backend/backend.yaml` | Collector with `client_ca_file` set ⇒ client certificate **required**; `file` exporter; read-only `evidence-reader` sidecar |
| Client namespace, client certificate, source-side NetworkPolicy | `lab/traffic-generator/` | senders are per-run Jobs rendered by `lab/lib/sender.sh` |
| Lab PKI + trust bundle | `lab/pki/` | explicit trust bootstrap, see below |
| Overlay | `lab/deploy/kustomization.yaml` | rendered with `kubectl kustomize --load-restrictor=LoadRestrictionsNone` (the flag is needed because it references plain files in `../../manifests`) |

NetworkPolicies installed: default-deny in `telemetry-secure` and `telemetry-clients`; gateway ingress
only from `telemetry-exporter=true` pods in namespaces labelled `telemetry-client=true`; gateway egress
only to the backend and kube-dns; **backend ingress only from the gateway**, backend egress none;
client egress only to the gateway and kube-dns.

### Trust bootstrap (explicit)

`pki/distribute-trust.sh` reads **only the public** `tls.crt` of `cert-manager/lab-root-ca`, validates that
it is a CA certificate, prints its SHA-256 fingerprint, and renders a `telemetry-trust-bundle` ConfigMap
into the three lab namespaces. Trust therefore originates with the operator running the script, never
with a telemetry sender. It runs from both `make lab-up` and `make deploy`.

## Safety properties

* **Dedicated kubeconfig.** `kind create cluster --kubeconfig lab/.kube/config`. Your `~/.kube/config` and
  current context are never read, merged, or changed. Every `kubectl`/`helm` call goes through
  `k`/`helmk` in `lib/common.sh`, which pin both the kubeconfig file and context `kind-zt-telemetry-lab`.
* **Ownership guard.** Before any apply, `guard_lab_context` checks the context name and the
  `zt-lab/owner` label on namespace `zt-lab-system`. A pre-existing kind cluster with the same name but no
  marker is **not adopted** and **not deleted**.
* **Scoped cleanup.** `make lab-down` runs `kind delete cluster --name zt-telemetry-lab` and removes
  `lab/.kube`, `lab/.work`. It touches no other cluster, Docker image, or Helm repo configuration.
  Cached images are left in Docker (remove them yourself if you want the space back).
* No private key is written outside the cluster by the lab. Tests read only `tls.crt` fields of Secrets.
  `lab/.kube/`, `lab/.work/` and `evidence/runs/` are gitignored.
* All telemetry is synthetic; no real credentials, endpoints or customer data.

## Resources (measured on one machine; treat as indicative)

| Measurement | Value | How |
|---|---|---|
| Docker memory in use, whole lab idle | ≈ 2.0 GiB (control-plane 1.2 GiB + worker 0.8 GiB) | `docker stats --no-stream` after deploy |
| Docker VM memory on the test machine | 7.75 GiB (shared with another unrelated kind cluster) | `docker info` |
| `make lab-up`, first run, base images partly cached | ≈ 2 min 10 s | script timestamps |
| `make lab-up` re-run (converge) | ≈ 10 s | `time` |
| `make deploy` | ≈ 13 s | `time` |
| `make send-telemetry` | ≈ 9 s | `time` |
| Disk | kindest/node image 1.5 GB + Collector 0.5 GB + chart images | `docker images` |

**Estimates (not measured):** a cold start with nothing cached will take longer, dominated by image pulls;
"≥ 6 GiB allocated to Docker" is a conservative recommendation, not a tested minimum. CPU requirement was
not measured separately (host has 12 cores).

## Troubleshooting

| Symptom | Likely cause / check |
|---|---|
| `no lab kubeconfig` | run `make lab-up` first |
| `refusing to adopt` / `refusing to delete` | a kind cluster named `zt-telemetry-lab` exists that this lab didn't create; rename or remove it yourself |
| Cilium install times out | `docker stats` — Docker memory too low; run `kubectl --kubeconfig lab/.kube/config -n kube-system get pods` (bootstrap prints diagnostics on failure) |
| Gateway pods `ContainerCreating` | trust bundle or certificate Secret missing: `make deploy` re-renders the bundle; check `lab/scripts/status.sh` |
| Gateway logs `transport: Error while dialing ... connection error` for ~10 s after first deploy | gateway started before the backend was ready; the exporter retries and recovers (observed during validation) |
| `sender job result: failed` with `i/o timeout` | NetworkPolicy path blocked (e.g. wrong namespace/pod labels) — this is a *network* failure, not an mTLS verdict |
| `sender ... certificate required` / `unknown certificate authority` | genuine TLS rejection: no client cert / client cert not from the trusted CA |
| `kubectl apply` of `rendered.yaml` fails with `namespaces ... not found` | the server-side dry-run is skipped on first deploy for this reason; re-run `make deploy` |

Hubble from the host: the `hubble` CLI is not required. The tests query flows through the Cilium agent
(`kubectl exec ds/cilium -- hubble observe ...`), which only sees flows of **its own node**.
To use the CLI against Hubble Relay: `kubectl --kubeconfig lab/.kube/config -n kube-system port-forward svc/hubble-relay 4245:80`
then `HUBBLE_SERVER=localhost:4245 hubble observe ...`. The existing `scripts/*.sh` use whatever kubectl context is
current, so point them at the lab explicitly: `export KUBECONFIG="$PWD/lab/.kube/config"` in that shell only.

## Changes to the blueprint

`manifests/` is reused as-is by `lab/deploy`, but running it against a real Collector exposed gaps, which
were fixed **in the blueprint itself** (not in a divergent lab copy):

1. Image bumped `0.136.0 → 0.163.2` after validating the existing config with `otelcol validate` on both versions (both accept it).
2. `limits.cpu` was missing — added (workload rules require requests *and* limits).
3. No readiness/liveness: the image is distroless (no shell), so a `health_check` extension and `httpGet` probes were added.
4. `02-networkpolicies.yaml` default-denies the namespace but contains no rule admitting the **backend**; the lab adds `otel-backend-allow` (`lab/backend/backend.yaml`). Any real backend needs the equivalent.

Known upstream drift: Collector 0.163 logs `"otlp" alias is deprecated; use "otlp_grpc"` (and `filelog` → `file_log`).
The blueprint still works but will need renaming before the aliases are removed.

## Limitations

* **One CA for every hop.** Any certificate from `telemetry-ca` is accepted by both the gateway and the
  backend. The backend does not check *which* identity connected; only NetworkPolicy keeps the traffic
  generator away from the backend (tested in `tests/test_network_isolation.sh`, case N4). Authorizing by
  SAN/identity would need per-hop issuers or an authorization layer.
* The backend is not storage: its file lives in an `emptyDir` and rotates at 8 MB.
* No encryption of Secrets at rest, no audit logging, no admission control are configured.
* NetworkPolicies are not applied to the Helm-installed `cert-manager`/`kube-system` components; they are
  third-party lab infrastructure in a disposable cluster.
* Only macOS/arm64 + Docker Desktop has been exercised.
