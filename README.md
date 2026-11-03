# Zero-Trust Telemetry: Reference Blueprints and Local Lab

Conference companion resources for evaluating and adapting security controls around OpenTelemetry and
Kubernetes telemetry pipelines.

**Status:** educational. A **runnable local lab** now exercises the mTLS gateway/backend blueprint on a
disposable kind cluster, with executable tests and one simulated "poisoned telemetry → denied action"
scenario. Everything else is still an **illustrative blueprint or future work** (table below). Nothing here
is audited, production-certified, battle-tested, or a turnkey deployment. Treat all labels, names,
endpoints, trust roots, versions, and policy selectors as environment-specific.

## What is runnable, what is illustrative, what is not done

| Area | State | Where |
|---|---|---|
| mTLS lab: kind + Cilium/Hubble + cert-manager + lab PKI + OTLP backend requiring client certs + synthetic client | **Runnable** (exercised on macOS/arm64 + Docker Desktop only) | [`lab/`](lab/README.md), `make lab-up deploy send-telemetry` |
| Executable security tests: receiver mTLS, exporter mTLS, network isolation, certificate rotation, delivery | **Runnable**; results are generated locally, not committed | [`tests/`](tests/README.md), `make test` |
| Poisoned log → denied action (deterministic simulation, not an LLM) | **Runnable** | [`scenarios/poisoned-log/`](scenarios/poisoned-log/README.md) |
| Worked threat model for the lab architecture | Written; status per claim | [`threat-model/WORKED-EXAMPLE.md`](threat-model/WORKED-EXAMPLE.md), [`docs/claims-and-evidence.md`](docs/claims-and-evidence.md) |
| Gateway Deployment, Certificate, NetworkPolicies | **Blueprint**, reused by the lab (with fixes, see lab README) | [`manifests/`](manifests/README.md) |
| Hubble inspection scripts | **Blueprint scripts**; usable against the lab | [`scripts/`](scripts/README.md) |
| Threat model template | Template | [`threat-model/TEMPLATE.md`](threat-model/TEMPLATE.md) |
| Prometheus federation authentication | **Not implemented** | — |
| Loki/Grafana tenant-isolated queries | **Not implemented** | — |
| Tamper-evident / append-only storage | **Not implemented** | — |
| Falco / Kubernetes audit detections | **Not implemented** | — |
| Tail-sampling manipulation (T1) | **Not implemented** | — |
| CI | **Not added yet** | — |

Evidence conventions are in [`evidence/README.md`](evidence/README.md). A test result is only claimed in
[`docs/claims-and-evidence.md`](docs/claims-and-evidence.md) if the case executed; `NOT RUN` is reported as
`NOT RUN`, never as passed.

## Quick start (lab)

```bash
make lab-up          # disposable cluster 'zt-telemetry-lab' with its OWN kubeconfig (lab/.kube/config)
make deploy          # gateway (manifests/), backend, client namespace
make send-telemetry  # send synthetic OTLP over mTLS and prove the backend recorded it
make test            # executable tests -> evidence/runs/<timestamp>/
make lab-down        # delete only this lab's cluster and generated files
```

Prerequisites, tested versions, resource measurements and troubleshooting: [`lab/README.md`](lab/README.md).
The lab never reads or changes your `~/.kube/config` or current context.

## Using the blueprints outside the lab

Blueprints in `manifests/` are not a complete cluster installation. Before attempting a real deployment:

- Use a **disposable or staging cluster** with a NetworkPolicy-enforcing CNI; Cilium/Hubble are required only for the Hubble scripts and the lab's Hubble corroboration.
- Install cert-manager and configure a **trusted** `ClusterIssuer` named `telemetry-ca` using your own PKI. The blueprint deliberately does not create a CA (the lab's `lab/pki/` does, **for the lab only**).
- Provision the `telemetry-trust-bundle` ConfigMap with `ca.crt` in `telemetry-secure` through a trusted distribution mechanism. The trust root must not be accepted from an untrusted telemetry sender.
- Provide an `otel-backend` workload in `telemetry-secure` with the `app: otel-backend` label and an OTLP/gRPC mTLS endpoint on 4317; its server certificate must match `otel-backend.telemetry-secure.svc.cluster.local`, **and add a NetworkPolicy admitting the gateway to it** (the blueprint's default-deny otherwise blocks it). A lab backend is in `lab/backend/`.
- Review Collector version and config fields, resource limits, cert reload behavior, namespace labels, DNS selectors, and source namespace egress policies.
- Only after review: `kubectl apply -f manifests/00-foundation.yaml`, then `01-certificates.yaml`, then `02-networkpolicies.yaml`. **Applying default-deny can interrupt workloads.**

## What these artifacts demonstrate (and do not)

- mTLS can authenticate peers and protect transport; it does not establish that the telemetry content itself is truthful. The poisoned-log scenario shows an authenticated producer delivering instruction-shaped text.
- cert-manager can renew/reissue certificates and rotate private keys; **zero-downtime rotation is conditional** on certificate/key reload (or safe rolling replacement), CA overlap, and successful connection tests. The rotation test *measures* one run; it does not establish a general guarantee, and does not cover CA rotation or the gateway exporter's client-cert reload.
- NetworkPolicy limits selected L3/L4 flows; it is not application-layer authorization or a substitute for credential hygiene. In the lab it is also what separates the producer from the backend, because all certificates share one CA.
- Hubble provides observed datapath verdicts from eBPF-backed telemetry. It **does not verify TLS identities, cryptographic integrity, or kernel isolation in full**. The eBPF verifier does not prove a policy is correct.
- The threat model includes Prometheus federation, logs, Falco, storage integrity, and AIOps; of these only the AIOps action-authorization path is simulated here.

### The six properties are kept separate

Peer authentication · transport protection · authorization · storage integrity · telemetry truthfulness ·
authorization of actions derived from telemetry. See
[WORKED-EXAMPLE §9](threat-model/WORKED-EXAMPLE.md#9-six-properties--what-the-lab-does-and-does-not-give-you)
for which the lab covers.

## Adaptation checklist

- [ ] Substitute real workload/service/namespace identities and validate selectors.
- [ ] Review PKI trust, certificate SANs, secret access, rotation and reload.
- [ ] Ensure ingress **and** egress allow rules on both ends of each connection.
- [ ] Confirm DNS reachability and backend authentication.
- [ ] Generate controlled allowed and denied flows; save evidence.
- [ ] Complete threat-model owners, likelihood, impacts, and residual risks.
- [ ] Perform security review before any production use.

## Primary documentation

- [https://opentelemetry.io/docs/collector/configuration/](https://opentelemetry.io/docs/collector/configuration/)
- [https://opentelemetry.io/docs/security/](https://opentelemetry.io/docs/security/)
- [https://cert-manager.io/docs/usage/certificate/](https://cert-manager.io/docs/usage/certificate/)
- [https://kubernetes.io/docs/concepts/services-networking/network-policies/](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [https://docs.cilium.io/en/stable/observability/hubble/hubble-cli/](https://docs.cilium.io/en/stable/observability/hubble/hubble-cli/)
- [https://prometheus.io/docs/operating/security/](https://prometheus.io/docs/operating/security/)
- [https://falco.org/docs/concepts/event-sources/plugins/kubernetes-audit/](https://falco.org/docs/concepts/event-sources/plugins/kubernetes-audit/)
