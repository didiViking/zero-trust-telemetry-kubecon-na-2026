#!/usr/bin/env python3
"""SIMULATED executor. It never runs anything. It prints what it WOULD run for allowed decisions and
refuses everything else, so tests can assert on exactly what would have been performed.
A proposal with no matching ALLOW decision is never "executed".
"""
import argparse
import json
import sys


def render(p):
    parts = [p["verb"], p["kind"]]
    if p.get("name"):
        parts.append(p["name"])
    if p.get("namespace"):
        parts += ["-n", p["namespace"]]
    return " ".join(parts)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--decisions", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    decisions = json.load(open(args.decisions, encoding="utf-8"))["decisions"]
    executed, blocked = [], []
    for d in decisions:
        (executed if d["effect"] == "allow" else blocked).append(render(d["proposal"]))
    with open(args.output, "w", encoding="utf-8") as fh:
        json.dump({"simulated": True, "would_execute": executed, "blocked": blocked}, fh, indent=2, sort_keys=True)
        fh.write("\n")
    for c in executed:
        print(f"executor-sim: WOULD RUN (simulated only): {c}", file=sys.stderr)
    for c in blocked:
        print(f"executor-sim: BLOCKED: {c}", file=sys.stderr)


if __name__ == "__main__":
    main()
