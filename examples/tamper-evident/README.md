# Tamper-evident records (detection only)

A ~150-line, standard-library hash-chain log with a separately protected checkpoint, and tests for
**modification, deletion, reordering, truncation**, and a full re-hash of the chain.

## This is tamper *detection*, not append-only enforcement

* A writable local file or directory is **not immutable**. The owner (or root) can edit, delete or replace it.
  `test_file_permissions_do_not_make_the_log_immutable` demonstrates that a read-only bit is no barrier.
* True append-only/WORM enforcement needs infrastructure this repo does not deploy (object-lock storage,
  a write-once service, `chattr +a` plus a privileged separation of duties, an external ledger…). **Not
  implemented here.**
* What you get: a verifier that reports `TAMPER DETECTED` with machine-readable findings when the log no
  longer matches what an authorized checkpoint holder anchored.

## Trust model (what the guarantee depends on)

| Attacker can… | Detected? |
|---|---|
| edit / delete / reorder records, chain not recomputed | **Yes** — `HASH_MISMATCH`, `SEQ_GAP_OR_REORDER`, `PREV_MISMATCH` |
| truncate to before the last checkpoint | **Yes** — `TRUNCATED_BEFORE_CHECKPOINT` |
| rewrite and **recompute the whole chain** | **Only because of the checkpoint** — `CHECKPOINT_HASH_MISMATCH` (the hash chain alone cannot detect this) |
| replace the checkpoint with one made using a wrong key | **Yes** — `CHECKPOINT_MAC_INVALID` |
| delete the checkpoint | **Yes, as failure** — `CHECKPOINT_MISSING` (never treated as success) |
| truncate only records written **after** the last checkpoint | **No** (documented limitation, asserted by a test) — checkpoint after each append or accept the window |
| hold the HMAC key | **No guarantee** |

The checkpoint file and its key must live in a **different trust domain** than the log (other host,
account, or service). In the tests they are separate files in one temp directory only to simulate that.
HMAC is symmetric: a verifier can also forge. Use asymmetric signatures (KMS/HSM-held Ed25519) if
verifiers must not be able to create checkpoints — not implemented.

## Run

```bash
python3 -I examples/tamper-evident/test_chainlog.py        # 10 tests
# demo
cd "$(mktemp -d)" && head -c 32 /dev/urandom | base64 > key          # throw-away key; keep it OFF the log's storage
python3 -I /path/to/chainlog.py append --log a.jsonl --message "synthetic event" --checkpoint cp.json --key-file key
python3 -I /path/to/chainlog.py verify --log a.jsonl --checkpoint cp.json --key-file key     # OK
sed -i.bak 's/synthetic/forged/' a.jsonl                                                    # tamper
python3 -I /path/to/chainlog.py verify --log a.jsonl --checkpoint cp.json --key-file key     # TAMPER DETECTED
```

Not connected to the lab backend: it does not make the lab's `emptyDir` file tamper-evident (that gap is
residual risk R8 in the worked threat model).
