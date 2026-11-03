# Kubernetes Security Blueprint — deployment assumptions

These YAML files are **illustrative starting points**, not a complete cluster installation.

| File | Purpose | Must adapt / provide |
|---|---|---|
| `00-foundation.yaml` | Namespace, gateway ConfigMap, Deployment and Service | Collector image/config compatibility, backend Service, CA trust bundle, readiness/availability, capacity |
| `01-certificates.yaml` | cert-manager Certificate for gateway | Trusted `telemetry-ca` ClusterIssuer, DNS names, key usages, certificate duration and secret controls |
| `02-networkpolicies.yaml` | Default-deny and OTLP/DNS allow rules | Namespace and pod labels, CNI enforcement, backend labels, CoreDNS labels, source-side egress |

## Identity and flow model

Approved source pod (`telemetry-exporter=true`) in an approved namespace (`telemetry-client=true`) → OTLP/gRPC 4317 → `otel-gateway` → OTLP/gRPC 4317 → `otel-backend`.

- The sample gateway certificate has both server and client authentication usages. Consider separate identities and keys for distinct roles in real deployments.
- Backend mTLS is **not configured by this package**; the backend must independently trust the gateway's client CA and present a valid server certificate. A lab backend that does this is in [`../lab/backend/`](../lab/README.md).
- `02-networkpolicies.yaml` default-denies the whole namespace but only opens the **gateway**. A backend in the same namespace also needs an ingress rule admitting the gateway (the lab adds `otel-backend-allow`); without it the gateway's exporter is blocked.
- The Collector image is distroless (no shell): readiness/liveness use `httpGet` against the `health_check` extension on 13133, which the gateway config now enables.
- Config was validated with `otelcol-contrib validate` on Collector 0.136.0 and 0.163.2 (both accepted it) and exercised at runtime on 0.163.2 in the lab only. Collector 0.163 warns that the `otlp` exporter/receiver aliases are deprecated in favour of `otlp_grpc`; rename before the aliases are removed.
- Kubernetes NetworkPolicy does not itself authenticate a peer; source labels and namespace labels are administrative controls that must be governed.
- DNS allowance assumes `k8s-app: kube-dns` in `kube-system`, which is not universal.
- Secret volume updates and Collector certificate reload must be validated against the deployed version. Restart/roll safely if hot reload is unsupported.
- A single CA replacement without overlapping trust can break active or new TLS connections. Plan trust-bundle overlap and staged rotation.
- Consider PodDisruptionBudget, readiness probes, autoscaling, rollout strategy, and telemetry buffering before production use; these are intentionally omitted here.

## Example-only deployment sequence (outside the lab)

1. Create or verify trusted PKI and `ClusterIssuer/telemetry-ca`.
2. Prepare the `telemetry-trust-bundle` ConfigMap and backend mTLS endpoint.
3. Review and adjust all YAML.
4. Apply the files in numeric order in a staging cluster.
5. Run the checks in `../VALIDATION.md`; do not infer success merely from `kubectl apply`.
