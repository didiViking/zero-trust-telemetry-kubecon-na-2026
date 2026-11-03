#!/usr/bin/env python3
"""Tamper-EVIDENT record log: a SHA-256 hash chain plus an HMAC-authenticated checkpoint kept in a
separate trust domain. Standard library only.

This is DETECTION, not PREVENTION. Nothing here stops anyone with write access from editing,
deleting, reordering or truncating the log file; the point is that such changes are detectable
by a verifier that holds the checkpoint and its key. It does not make a directory immutable.

Log format (JSON Lines, one record per line):
  {"seq": N, "ts": "...", "payload": {...}, "prev": "<hex>", "hash": "<hex>"}
  hash = SHA-256(canonical_json({"seq","ts","payload","prev"}))   ; first record's prev = "0"*64
Checkpoint (separate file, ideally on separate storage/host/account):
  {"seq": N, "hash": "<hex of record N>", "mac": "<HMAC-SHA256(key, 'seq:hash')>"}

Trust model for the checkpoint (what the guarantees depend on):
  * Attacker can write the log, cannot write the checkpoint file, cannot read the key  -> any edit,
    delete, reorder, or truncation back past the checkpoint is detected, including a fully recomputed
    (re-hashed) chain, because the head hash no longer matches the authenticated checkpoint.
  * Attacker can also write the checkpoint but lacks the key                           -> forged
    checkpoint fails MAC verification; they can still delete/replace it (detected as "missing").
  * Attacker holds the key                                                              -> no guarantee.
  * HMAC is symmetric: anyone who can VERIFY can also FORGE. For separation of duties use an
    asymmetric signature (e.g. Ed25519 via an HSM/KMS) -- not implemented here.
  * Records appended after the last checkpoint are "unanchored": truncating only those is NOT
    detectable. Checkpoint after every append, or accept that window.
"""
import argparse
import datetime
import hashlib
import hmac
import json
import os
import sys

GENESIS = "0" * 64


def _canon(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()


def record_hash(seq, ts, payload, prev):
    return hashlib.sha256(_canon({"seq": seq, "ts": ts, "payload": payload, "prev": prev})).hexdigest()


def _mac(key, seq, head):
    return hmac.new(key, f"{seq}:{head}".encode(), hashlib.sha256).hexdigest()


def read_log(path):
    recs = []
    if not os.path.exists(path):
        return recs
    with open(path, encoding="utf-8") as fh:
        for n, line in enumerate(fh, 1):
            line = line.rstrip("\n")
            if line:
                try:
                    recs.append(json.loads(line))
                except json.JSONDecodeError:
                    recs.append({"_corrupt_line": n})
    return recs


def append(log_path, payload, ts=None):
    """Append one record. Returns the new record. Opens in append mode but this is a convention,
    not enforcement."""
    recs = read_log(log_path)
    prev = recs[-1].get("hash", GENESIS) if recs else GENESIS
    seq = (recs[-1].get("seq", -1) + 1) if recs else 0
    ts = ts or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    rec = {"seq": seq, "ts": ts, "payload": payload, "prev": prev, "hash": record_hash(seq, ts, payload, prev)}
    with open(log_path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(rec, sort_keys=True) + "\n")
    return rec


def write_checkpoint(log_path, checkpoint_path, key):
    recs = read_log(log_path)
    if not recs:
        raise SystemExit("cannot checkpoint an empty log")
    head = recs[-1]
    cp = {"seq": head["seq"], "hash": head["hash"], "mac": _mac(key, head["seq"], head["hash"])}
    tmp = checkpoint_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(cp, fh, sort_keys=True)
    os.replace(tmp, checkpoint_path)
    return cp


def verify(log_path, checkpoint_path, key):
    """Return (ok, findings). findings is a list of machine-readable strings; empty iff ok."""
    findings = []
    recs = read_log(log_path)
    prev = GENESIS
    for i, r in enumerate(recs):
        if "_corrupt_line" in r:
            findings.append(f"CORRUPT_LINE:{r['_corrupt_line']}")
            continue
        if r.get("seq") != i:
            findings.append(f"SEQ_GAP_OR_REORDER:index={i},seq={r.get('seq')}")
        if r.get("prev") != prev:
            findings.append(f"PREV_MISMATCH:seq={r.get('seq')}")
        if r.get("hash") != record_hash(r.get("seq"), r.get("ts"), r.get("payload"), r.get("prev")):
            findings.append(f"HASH_MISMATCH:seq={r.get('seq')}")
        prev = r.get("hash", prev)
    # --- anchor against the separately protected checkpoint
    if not os.path.exists(checkpoint_path):
        findings.append("CHECKPOINT_MISSING")
        return False, findings
    try:
        with open(checkpoint_path, encoding="utf-8") as fh:
            cp = json.load(fh)
        expected = _mac(key, cp["seq"], cp["hash"])
    except (ValueError, KeyError, TypeError):
        findings.append("CHECKPOINT_MALFORMED")
        return False, findings
    if not hmac.compare_digest(expected, str(cp.get("mac", ""))):
        findings.append("CHECKPOINT_MAC_INVALID")
        return False, findings
    by_seq = {r.get("seq"): r for r in recs if "_corrupt_line" not in r}
    if cp["seq"] >= len(recs) or cp["seq"] not in by_seq:
        findings.append(f"TRUNCATED_BEFORE_CHECKPOINT:checkpoint_seq={cp['seq']},log_len={len(recs)}")
    elif by_seq[cp["seq"]].get("hash") != cp["hash"]:
        findings.append(f"CHECKPOINT_HASH_MISMATCH:seq={cp['seq']}")
    return (not findings), findings


def _key(path):
    with open(path, "rb") as fh:
        k = fh.read().strip()
    if len(k) < 16:
        raise SystemExit("key file too short (>=16 bytes required)")
    return k


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("append"); a.add_argument("--log", required=True); a.add_argument("--message", required=True)
    a.add_argument("--checkpoint"); a.add_argument("--key-file")
    c = sub.add_parser("checkpoint"); c.add_argument("--log", required=True); c.add_argument("--checkpoint", required=True); c.add_argument("--key-file", required=True)
    v = sub.add_parser("verify"); v.add_argument("--log", required=True); v.add_argument("--checkpoint", required=True); v.add_argument("--key-file", required=True)
    args = ap.parse_args()
    if args.cmd == "append":
        rec = append(args.log, {"message": args.message})
        if args.checkpoint and args.key_file:
            write_checkpoint(args.log, args.checkpoint, _key(args.key_file))
        print(f"appended seq={rec['seq']} hash={rec['hash'][:16]}")
    elif args.cmd == "checkpoint":
        cp = write_checkpoint(args.log, args.checkpoint, _key(args.key_file))
        print(f"checkpoint seq={cp['seq']} hash={cp['hash'][:16]}")
    else:
        ok, findings = verify(args.log, args.checkpoint, _key(args.key_file))
        print("OK: chain intact and anchored to checkpoint" if ok else "TAMPER DETECTED: " + "; ".join(findings))
        sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
