# Lab PKI and trust bootstrap

## What the lab does (LAB ONLY)

1. `issuers.yaml` creates a self-signed bootstrap issuer, a root CA certificate
   (`cert-manager/lab-root-ca`, ECDSA P-256) and the `telemetry-ca` ClusterIssuer that the
   repository's `manifests/01-certificates.yaml` expects.
2. `distribute-trust.sh` is the **explicit trust-bootstrap step**. The operator (you, via
   `make lab-up` / `make deploy`) reads the *public* CA certificate from the Secret, prints its
   SHA-256 fingerprint, and renders `telemetry-trust-bundle` ConfigMaps into
   `telemetry-secure`, `telemetry-clients` and `telemetry-untrusted`.
   Trust originates with the PKI owner; no telemetry sender can add itself to a trust bundle.

## Why this is not production guidance

| Lab shortcut | Why it is unacceptable in production |
|---|---|
| CA private key stored in a Kubernetes Secret | Anyone with `get secret` in `cert-manager` can mint any identity. Use an HSM/KMS/Vault-backed or external issuer; keep the root offline. |
| One CA for client->gateway and gateway->backend | Any certificate from this CA is accepted by both hops; identity separation then rests on NetworkPolicy alone. Use separate issuers/trust bundles per hop, or add SAN/identity-based authorization. |
| Root CA signs leaf certificates directly | Use an offline root and online intermediates, so the root key is never exposed to the cluster. |
| Trust bundle copied once by a script | Use a managed distribution mechanism (e.g. trust-manager) with rotation overlap. |
| Test-client private keys in Secrets readable by cluster admin | Scope Secret RBAC; prefer short-lived workload identity. |

Authenticated is not truthful: a producer holding a valid certificate can still emit
misleading telemetry (see `scenarios/` once Phase 3 lands).
