# Conference release checklist

For cutting a tagged snapshot of this repository to accompany the talk. **Nothing in this repo creates,
pushes or tags a release automatically**; every step that publishes needs a person's explicit go-ahead.

## 1. Content honesty (blocking)

- [ ] `README.md` status table matches reality: each "Runnable" row has been executed on the commit being released.
- [ ] No text claims *production-ready, audited, battle-tested, certified, or zero-downtime*. Search: `grep -rniE 'production[- ]ready|battle|audited|zero[- ]downtime|certified' --include='*.md' .` and read every hit in context (the hits that say "not …" are fine).
- [ ] Every claim in [`claims-and-evidence.md`](claims-and-evidence.md) has an execution status that is true *for the release commit*; entries re-run after the last code change.
- [ ] Mismatches between the talk abstract and the repo are listed in the release notes (see "Known gaps" below).
- [ ] Vendor-neutral wording preserved (the architecture is Collector + Kubernetes primitives; Cilium/Hubble named only as the lab's CNI/observer).

## 2. Reproducibility (blocking)

- [ ] Working tree clean and **committed** (`git status` empty). Evidence from a dirty tree must not be cited.
- [ ] From a machine with nothing cached if possible: `make lab-down; make lab-up deploy send-telemetry test`. Record wall time and Docker memory.
- [ ] `make test` exit code recorded. Exit `3` (NOT RUN present) is acceptable only if each NOT RUN is listed in the release notes with its reason.
- [ ] `make check` (static) green locally and in CI.
- [ ] Versions in `lab/versions.env` re-verified against upstream support matrices; image digests/tags still pullable.
- [ ] `make lab-down` leaves no kind cluster `zt-telemetry-lab`, no `lab/.kube`, no `lab/.work`; other clusters/contexts untouched (`kubectl config get-contexts` before and after).

## 3. Security hygiene (blocking)

- [ ] `git ls-files | xargs grep -lE 'BEGIN [A-Z ]*PRIVATE KEY'` finds nothing; no kubeconfigs committed (`lab/.kube/` is gitignored).
- [ ] No real hostnames, tokens, emails, internal registry names, or customer data in docs, evidence, or fixtures.
- [ ] Evidence bundle (if attached to the release) was **read** in full after sanitization — see [`evidence/README.md`](../evidence/README.md).
- [ ] GitHub Actions: workflow `permissions` still `contents: read`; third-party actions still pinned to reviewed SHAs (re-verify tag → SHA when bumping); no `pull_request_target`; no secrets referenced.
- [ ] Repository settings (branch protection, Actions permissions) reviewed by the maintainer. This repo's tooling never changes them.

## 4. CI notes

* `static` job: well-formedness only (ShellCheck, yamllint, Python unit tests, overlay rendering with a throw-away CA, pinned-Collector `validate`, kubeconform with cert-manager CRD schemas). **No badge** is provided because a green run does not show any security control works.
* `integration` job: manual (`workflow_dispatch` with `run_integration`). Requires a runner where Docker can start the kind node containers (GitHub-hosted `ubuntu-24.04` is expected to work, **unverified**) and a kernel recent enough for Cilium's eBPF datapath. It uses no `--privileged` job container. Do not run it on a runner that holds credentials for other environments. Add a badge for it only after it has passed on the runner type you advertise.

## 5. Publish (explicit approval required for each)

- [ ] Maintainer approves the release notes and tag name.
- [ ] Tag created and pushed by the maintainer: `git tag -a vX.Y.Z -m "…"` → `git push origin vX.Y.Z` (never `--force`).
- [ ] GitHub release drafted from the tag (draft first; publish after proofreading).
- [ ] Slides/QR link points at the tag, not `main`.

## Known gaps to state in the release notes (update before release)

- Prometheus federation authentication, Loki/Grafana tenant isolation, WORM/append-only storage, Falco/audit detection, and tail-sampling (T1) scenarios are **not implemented**; only a standalone detection-only hash-chain example exists (`examples/tamper-evident/`).
- The AIOps consumer is a deterministic simulation, not an LLM.
- One CA signs every hop in the lab; no identity-level authorization.
- Rotation: CA-overlap rotation and gateway-exporter client-cert reload are NOT RUN.
- Only macOS/arm64 + Docker Desktop has been exercised.
