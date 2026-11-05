# Getting started (first time with a lab like this)

Goal: in a few minutes (measured: 164 s with images already cached; a cold start is longer and unmeasured) you will have a throw-away
Kubernetes cluster on your laptop and **see four things happen**:

1. A client with a valid certificate sends telemetry and it arrives.
2. The same client without its certificate is **rejected by TLS**.
3. A pod in the wrong namespace is **blocked by the network** (a different control — it looks different).
4. A *poisoned* log line, sent by a fully authenticated client, is accepted — but the dangerous action it
   tries to trigger is **denied**.

Nothing touches your real clusters: the lab creates its own cluster (`zt-telemetry-lab`) and its own
kubeconfig file, and `make lab-down` removes it. Only macOS (Apple silicon) with Docker Desktop has been
tested.

## 1. Install the prerequisites

You need Docker, kind, kubectl, Helm, jq and openssl. On macOS with Homebrew:

```bash
brew bundle --file=Brewfile      # review the file first; this installs software
open -a Docker                   # start Docker Desktop, wait until it says "running"
```

In Docker Desktop → Settings → Resources, give Docker **at least 6 GiB of memory** (the lab uses about 2).
Other platforms: install the same tools yourself (Linux is untested).

Then check:

```bash
make doctor
```

It changes nothing; it lists what is missing and how to fix it.

## 2. Run the guided path

```bash
make quickstart
```

This does `lab-up` (cluster + networking + certificate manager + a lab-only certificate authority),
`deploy` (gateway, backend, client namespace) and `demo`. The first run downloads a few GB of images, so
expect a few minutes; later runs are much faster. You will see the four steps above, each followed by a line
beginning `OK:` that says what it proved. If a step is not what was narrated, the demo says `UNEXPECTED`
and exits non-zero.

### What the four steps mean

| Step | What you saw | Why it matters |
|---|---|---|
| 1 | `PASS backend received traces/metrics/logs` | The sender stamps a unique run id into every record; the script finds that id **at the backend**. "The sender exited 0" is never treated as proof. |
| 2 | `tls: certificate required` | **Peer authentication.** The gateway insisted on a client certificate. |
| 3 | `gateway rc=1 elapsed=4`, plus a Hubble `Policy denied DROPPED` line | **Network authorization.** The packets were silently dropped, so the connection hangs instead of failing with a TLS error. Two controls, two different symptoms. Hubble *corroborates* the drop; it does not prove TLS or isolation. |
| 4 | `delete deployment -> DENY` | **mTLS says who sent it, not whether it is true.** The log was accepted. Only a separate, default-deny check on the *action* stopped the damage. The "AI agent" here is a deterministic simulation, not a real model. |

## 3. Look around yourself

The lab never changes your default kubectl context, so tell kubectl to use the lab's kubeconfig **in this
terminal only**:

```bash
export KUBECONFIG="$PWD/lab/.kube/config"
kubectl get pods -n telemetry-secure                  # gateway x2, backend
kubectl get networkpolicy -n telemetry-secure         # default-deny + the few allows
kubectl get certificate -A                            # certificates issued by the lab CA
kubectl -n telemetry-secure exec deploy/otel-backend -c evidence-reader -- tail -c 600 /data/otlp.jsonl
for p in $(kubectl -n kube-system get pod -l k8s-app=cilium -o name); do   # one Cilium agent per node
  kubectl -n kube-system exec "$p" -c cilium-agent -- hubble observe --verdict DROPPED --port 4317 --last 3 -o compact
done
unset KUBECONFIG                                      # back to your normal clusters
```

The `tail` shows what the backend actually received. The Hubble loop shows recent connections to port 4317
that were dropped (run `make demo` first so there is something to see; each agent only knows its own node,
and the flow buffer is small, so old drops disappear).

## 4. Go deeper (optional)

| Command | Time | What it does |
|---|---|---|
| `make send-telemetry` | ~10 s | repeat step 1 with a fresh run id |
| `make test-quick` | ~3 min (measured 168 s) | all security tests except certificate rotation; evidence goes to `evidence/runs/` |
| `make test` | ~7 min (measured 420–428 s) | everything, including a 4-minute certificate-rotation measurement |

Read next: [lab/README.md](README.md) (architecture, safety properties, limits),
[tests/README.md](../tests/README.md) (how to read PASS / FAIL / NOT RUN),
[threat-model/WORKED-EXAMPLE.md](../threat-model/WORKED-EXAMPLE.md) (what is and is not covered).

## 5. Clean up

```bash
make lab-down
```

Deletes only the `zt-telemetry-lab` cluster and the lab's generated files. Downloaded images stay in
Docker; remove them with Docker Desktop if you want the disk back.

## Small glossary

* **mTLS** — both sides present certificates, so the server also knows *who* is connecting.
* **Certificate authority (CA)** — the issuer both sides trust. The lab makes its own; never copy that setup to production.
* **cert-manager** — a Kubernetes add-on that issues and renews certificates automatically.
* **NetworkPolicy** — Kubernetes firewall rules between pods. "Default deny" blocks everything not explicitly allowed.
* **Hubble** — a view of what the network layer allowed or dropped.
* **OTLP / OpenTelemetry Collector** — the telemetry protocol and the gateway program that receives it.

## If something goes wrong

`make doctor` first. Then the troubleshooting table in [lab/README.md](README.md#troubleshooting). You can
always `make lab-down` and start again; it is safe to repeat.
