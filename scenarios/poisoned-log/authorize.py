#!/usr/bin/env python3
"""Policy enforcement point for actions proposed by automation. A SEPARATE program from the agent:
it shares no code or state with mock-agent.py and trusts nothing in a proposal except its structured
fields, which it re-validates. Explicit deny wins; anything unmatched is denied.

It evaluates and records decisions only. It does not execute anything.
"""
import argparse
import hashlib
import json
import sys

READ_ONLY_VERBS = {"get", "list", "describe", "logs"}


def effective_mutating(p):
    # Do NOT trust the proposer's own `mutating` flag: derive it from the verb as well.
    return bool(p.get("mutating")) or p.get("verb") not in READ_ONLY_VERBS


def matches(rule_match, p):
    if "mutating" in rule_match and effective_mutating(p) != rule_match["mutating"]:
        return False
    if "verbs" in rule_match and p.get("verb") not in rule_match["verbs"]:
        return False
    if "kinds" in rule_match and p.get("kind") not in rule_match["kinds"]:
        return False
    if "namespaces" in rule_match and p.get("namespace") not in rule_match["namespaces"]:
        return False
    return True


def decide(policy, p):
    for rule in policy["rules"]:
        if rule["effect"] == "deny" and matches(rule["match"], p):
            return "deny", rule["id"], rule["reason_code"], rule["reason"]
    for rule in policy["rules"]:
        if rule["effect"] == "allow" and matches(rule["match"], p):
            return "allow", rule["id"], rule["reason_code"], rule["reason"]
    return policy["default_effect"], "default", "DENY_DEFAULT", "no allow rule matched; default deny"


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--proposals", required=True)
    ap.add_argument("--policy", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    raw = open(args.policy, "rb").read()
    policy = json.loads(raw)
    if policy.get("default_effect") != "deny":
        print("authorize: refusing policy without default_effect=deny", file=sys.stderr)
        sys.exit(2)
    props = json.load(open(args.proposals, encoding="utf-8"))["proposals"]
    decisions = []
    for p in props:
        effect, rule_id, code, reason = decide(policy, p)
        decisions.append({
            "proposal_id": p["id"], "effect": effect, "rule": rule_id,
            "reason_code": code, "reason": reason,
            "proposal": {k: p.get(k) for k in ("verb", "kind", "name", "namespace", "mutating", "derived_from")},
        })
    out = {"policy_sha256": hashlib.sha256(raw).hexdigest(), "decisions": decisions}
    with open(args.output, "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=2, sort_keys=True)
        fh.write("\n")
    for d in decisions:
        print(f"authorize: {d['proposal_id']} {d['proposal']['verb']} {d['proposal']['kind']} -> {d['effect'].upper()} ({d['reason_code']})", file=sys.stderr)


if __name__ == "__main__":
    main()
