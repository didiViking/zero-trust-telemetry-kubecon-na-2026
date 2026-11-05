# Evidence

Test runs write machine-readable evidence to `evidence/runs/<UTC timestamp>/` (gitignored by default).
Nothing under `evidence/runs/` is committed automatically: results are only meaningful alongside the
exact commit, cluster and versions that produced them, and a stale `PASS` file is worse than none.

## Layout of one run

| File | Content |
|---|---|
| `meta.json` | git commit **and whether the working tree was dirty**, UTC start time, cluster identity (context, API server URL, `kube-system` namespace UID, node names, Kubernetes server version), Helm releases (chart + app version), deployed image tags, contents of `lab/versions.env` |
| `results.jsonl` | one JSON object per case, appended as tests run |
| `results.json` | `meta` + `summary {pass, fail, not_run}` + all `results` (written when the run finishes) |
| `scenario-poisoned-log/` | proposals, authorization decisions, simulated-execution record for the Phase 3 scenario |

Each result: `test`, `case`, `status` (`PASS` \| `FAIL` \| `NOT RUN`), `time_utc`, `description`, `expected`,
`actual`, `diagnostic` (sanitized, ≤ 1500 chars).

### Status meanings

* **PASS** — the case executed and the observed outcome matched the expected outcome, *including* any
  positive control the case depends on.
* **FAIL** — it executed and the outcome differed, or a precondition that should hold did not.
* **NOT RUN** — it could not be executed or interpreted (e.g. the positive control failed, Hubble was
  unreachable, an observation is impossible in this lab). **NOT RUN is never a pass**: `tests/run-all.sh`
  exits non-zero (3) if any case is NOT RUN and none failed.

## Citing results

Cite a run only if its `meta.json` has `working_tree_dirty: false`, the `git_commit` is the commit being
released, and the run was a clean-room procedure (`make lab-down` first). Anything else is a development
observation.

## Sanitization

* Scripts read only the public `tls.crt` of Secrets (via jsonpath); `tls.key` / `ca` private keys are never
  read, logged, or copied.
* All diagnostic text passes through `sanitize` (`lab/lib/common.sh`): PEM private-key blocks are
  replaced, `Bearer …` tokens and `token|password|secret = …` values are masked, and fields are length-capped.
* Telemetry in the lab is synthetic. Sender/gateway logs include pod IPs and the lab's cluster-internal
  names; review before sharing outside your team.
* Sanitization is pattern-based and **best effort**. Read an evidence bundle before publishing it.

## Retention

* Treat each run directory as an immutable artifact; do not edit it. Re-run instead.
* Keep the run(s) cited by `docs/claims-and-evidence.md` for as long as the claim is made; delete the rest.
* `evidence/runs/` is gitignored on purpose. To publish a run (e.g. as a release asset), copy the directory,
  review it, and note the commit hash from `meta.json`. Results with `working_tree_dirty: true` do not
  describe any commit and should not be cited as evidence for one.
* The lab teardown does not remove `evidence/`.
