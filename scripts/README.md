# eBPF Flow Verification Blueprint

These are **runnable example scripts** that use Hubble's eBPF-backed flow telemetry. They do **not** inspect eBPF programs or certify kernel isolation.

## Prerequisites

- `kubectl` context and permissions to inspect the target namespace's NetworkPolicies and pods.
- Cilium with Hubble enabled, Hubble Relay accessible, and a working `hubble` CLI.
- An explicitly approved staging environment to generate test traffic. Scripts themselves do not generate attacks or mutate policies.

## Usage

These scripts use whatever `kubectl` context is current. To point them at the local lab without touching your default context, set `KUBECONFIG` for that shell only: `export KUBECONFIG="$PWD/lab/.kube/config"` (see [lab/README.md](../lab/README.md) for Hubble Relay access). The lab's own tests query Hubble through the Cilium agent instead and do not need the `hubble` CLI.

```bash
NAMESPACE=telemetry-secure bash scripts/check-policy.sh
DEST=telemetry-secure/otel-gateway OUT=./evidence bash scripts/verify-flows.sh
DEST=telemetry-secure/otel-gateway bash scripts/watch-denied.sh
```

`check-policy.sh` prints installed policy, Certificate and Deployment state; it is **not** a policy correctness proof.

`verify-flows.sh` saves policy YAML, pod inventory, Hubble status, recent flows in JSON, and `DROPPED`/`FORWARDED` subsets. These are **observations**, not a guaranteed complete traffic history. Verify Hubble CLI option support for your installed version.

`watch-denied.sh` streams observed drops to the target pod until interrupted.

## Controlled validation

1. From an **approved** source pod, attempt a legitimate OTLP connection and record an observed `FORWARDED` flow.
2. From a deliberately **unapproved test pod**, attempt the same connection and record an observed `DROPPED` flow.
3. Verify both identities, ports, and direction in Hubble output, and compare with policy selectors.
4. Save timestamps, Kubernetes context, policy snapshot, CLI versions, and evidence path.

**Interpretation limits:** an empty dropped-flow file is not proof that deny rules work; `FORWARDED` is not proof of TLS success; a drop may reflect reasons other than NetworkPolicy. Use an application-level mTLS handshake check as a separate test. NetworkPolicy enforcement requires a supporting CNI and correctly selected pods.
