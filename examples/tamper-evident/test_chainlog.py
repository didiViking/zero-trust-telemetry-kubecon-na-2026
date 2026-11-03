"""Tests for chainlog.py (standard library `unittest`). Run: python3 -I -m unittest -v test_chainlog
from this directory, or `python3 -I examples/tamper-evident/test_chainlog.py` from the repo root."""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import chainlog as c  # noqa: E402

KEY = b"test-only-key-not-a-secret-0123456789"
OTHER_KEY = b"attacker-guess-key-0123456789abcdef"


class ChainTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory()
        self.log = os.path.join(self.d.name, "audit.jsonl")
        self.cp = os.path.join(self.d.name, "checkpoint.json")   # stands in for SEPARATE storage
        for i in range(6):
            c.append(self.log, {"event": f"synthetic-{i}"}, ts=f"2026-01-01T00:00:0{i}Z")
        c.write_checkpoint(self.log, self.cp, KEY)

    def tearDown(self):
        self.d.cleanup()

    def lines(self):
        with open(self.log, encoding="utf-8") as fh:
            return fh.read().splitlines()

    def put(self, lines):
        with open(self.log, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")

    def rewrite_consistently(self, records):
        """Attacker who can write the log recomputes seq/prev/hash so the chain alone looks valid."""
        prev, out = c.GENESIS, []
        for i, r in enumerate(records):
            h = c.record_hash(i, r["ts"], r["payload"], prev)
            out.append(json.dumps({"seq": i, "ts": r["ts"], "payload": r["payload"], "prev": prev, "hash": h}, sort_keys=True))
            prev = h
        self.put(out)

    def test_untouched_log_verifies(self):
        ok, f = c.verify(self.log, self.cp, KEY)
        self.assertTrue(ok, f)

    def test_modification_detected(self):
        ls = self.lines(); r = json.loads(ls[2]); r["payload"]["event"] = "EDITED"; ls[2] = json.dumps(r, sort_keys=True)
        self.put(ls)
        ok, f = c.verify(self.log, self.cp, KEY)
        self.assertFalse(ok); self.assertTrue(any(x.startswith("HASH_MISMATCH") for x in f), f)

    def test_deletion_detected(self):
        ls = self.lines(); del ls[2]; self.put(ls)
        ok, f = c.verify(self.log, self.cp, KEY)
        self.assertFalse(ok); self.assertTrue(any("SEQ_GAP" in x or "PREV_MISMATCH" in x for x in f), f)

    def test_reordering_detected(self):
        ls = self.lines(); ls[1], ls[2] = ls[2], ls[1]; self.put(ls)
        ok, f = c.verify(self.log, self.cp, KEY)
        self.assertFalse(ok); self.assertTrue(any("SEQ_GAP_OR_REORDER" in x for x in f), f)

    def test_truncation_past_checkpoint_detected(self):
        self.put(self.lines()[:3])          # checkpoint anchors seq 5
        ok, f = c.verify(self.log, self.cp, KEY)
        self.assertFalse(ok); self.assertTrue(any(x.startswith("TRUNCATED_BEFORE_CHECKPOINT") for x in f), f)

    def test_consistent_rewrite_detected_only_via_checkpoint(self):
        recs = [json.loads(x) for x in self.lines()]
        recs[2]["payload"] = {"event": "REWRITTEN"}
        self.rewrite_consistently(recs)
        # without an anchor the rewritten chain is internally valid ...
        self.assertEqual([x for x in c.verify(self.log, self.cp + ".none", KEY)[1] if not x.startswith("CHECKPOINT")], [])
        # ... with the authenticated checkpoint it is caught
        ok, f = c.verify(self.log, self.cp, KEY)
        self.assertFalse(ok); self.assertIn("CHECKPOINT_HASH_MISMATCH:seq=5", f)

    def test_forged_checkpoint_without_key_rejected(self):
        recs = [json.loads(x) for x in self.lines()]; recs[2]["payload"] = {"event": "REWRITTEN"}
        self.rewrite_consistently(recs)
        c.write_checkpoint(self.log, self.cp, OTHER_KEY)    # attacker re-anchors with the wrong key
        ok, f = c.verify(self.log, self.cp, KEY)
        self.assertFalse(ok); self.assertIn("CHECKPOINT_MAC_INVALID", f)

    def test_missing_checkpoint_is_a_failure_not_a_pass(self):
        os.remove(self.cp)
        ok, f = c.verify(self.log, self.cp, KEY)
        self.assertFalse(ok); self.assertIn("CHECKPOINT_MISSING", f)

    def test_known_limit_unanchored_tail_truncation_is_not_detected(self):
        """DOCUMENTED LIMITATION: records after the last checkpoint are not protected."""
        c.append(self.log, {"event": "after-checkpoint"})       # seq 6, no new checkpoint
        self.put(self.lines()[:-1])                              # attacker removes only that record
        ok, f = c.verify(self.log, self.cp, KEY)
        self.assertTrue(ok, "truncation back to the checkpoint is indistinguishable from never having appended")

    def test_file_permissions_do_not_make_the_log_immutable(self):
        """A read-only bit does not stop the owner: this is why it is detection, not append-only."""
        os.chmod(self.log, 0o444)
        os.chmod(self.log, 0o644)                                # owner can undo it
        with open(self.log, "a", encoding="utf-8") as fh:
            fh.write("")
        self.assertTrue(os.access(self.log, os.W_OK))


if __name__ == "__main__":
    unittest.main(verbosity=2)
