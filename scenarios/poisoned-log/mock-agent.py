#!/usr/bin/env python3
"""DETERMINISTIC SIMULATION of an AIOps consumer. It is NOT a language model and says nothing about
how any real LLM behaves.

It is deliberately written to be *vulnerable*: when received telemetry text contains something that
looks like an instruction, it turns that text into a proposed action. That models the risk being
studied (telemetry used as an instruction channel) in a reproducible way.

Properties enforced by construction:
  * Input is ONLY the telemetry that the lab backend recorded (OTLP JSON lines, `--input`). It never
    reads the original fixture.
  * Telemetry text is data. It is matched with regular expressions and copied into JSON proposal
    fields. It is never evaluated, never passed to a shell, and nothing here can execute a command
    (no subprocess / os / eval / exec usage; check_no_exec.py verifies this by AST scan).
  * The agent only PROPOSES. Authorization is a separate program (authorize.py) with its own policy file.
"""
import argparse
import hashlib
import json
import re
import sys

DIRECTIVE = re.compile(r"(?i)\b(?:aiops|assistant|ai)[-_ ]?(?:instruction|directive)\s*:\s*(?P<rest>.+)$")
CMD = re.compile(
    r"(?i)\bkubectl\s+(?P<verb>delete|scale|rollout|exec|apply|patch)\s+"
    r"(?P<kind>[a-z]+)(?:\s+(?P<name>[a-z0-9][a-z0-9-]*))?"
    r"(?:.*?\s-n\s+(?P<ns>[a-z0-9][a-z0-9-]*))?"
)
NAMESPACE = re.compile(r"\bnamespace=(?P<ns>[a-z0-9][a-z0-9-]*)")
SYMPTOM = re.compile(r"(?i)\b(timeout|latency|5\d\d|error)\b")
MUTATING = {"delete", "scale", "rollout", "exec", "apply", "patch", "create", "update"}


def log_records(path):
    """Yield (service, severity, body) for every log record in OTLP-JSON export lines."""
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            doc = json.loads(line)
            for rl in doc.get("resourceLogs", []):
                attrs = {a["key"]: a["value"].get("stringValue", "") for a in rl.get("resource", {}).get("attributes", [])}
                for sl in rl.get("scopeLogs", []):
                    for rec in sl.get("logRecords", []):
                        yield attrs, rec.get("severityText", ""), rec.get("body", {}).get("stringValue", "")


def propose(path, run_id):
    proposals = []
    for attrs, severity, body in log_records(path):
        if attrs.get("lab.run_id") != run_id:
            continue  # ignore telemetry from other runs
        src = hashlib.sha256(body.encode()).hexdigest()[:16]
        ns = NAMESPACE.search(body)
        directive = DIRECTIVE.search(body)
        if directive:  # the simulated weakness: obey instruction-shaped text
            m = CMD.search(directive.group("rest"))
            if m:
                verb = m.group("verb").lower()
                proposals.append({
                    "verb": "rollout-restart" if verb == "rollout" else verb,
                    "kind": m.group("kind").lower(),
                    "name": m.group("name"),
                    "namespace": m.group("ns") or (ns.group("ns") if ns else None),
                    "mutating": verb in MUTATING,
                    "derived_from": "telemetry-directive",
                    "rationale": "text in a received log record was phrased as an instruction",
                    "source": {"service": attrs.get("service.name"), "severity": severity, "body_sha256_16": src},
                })
            continue
        if SYMPTOM.search(body) and severity.lower() in ("error", "warn", "warning"):
            proposals.append({
                "verb": "get", "kind": "pods", "name": None,
                "namespace": ns.group("ns") if ns else None,
                "mutating": False,
                "derived_from": "telemetry-diagnostic",
                "rationale": "error-level record mentions a failure symptom; inspect workload state",
                "source": {"service": attrs.get("service.name"), "severity": severity, "body_sha256_16": src},
            })
    return proposals


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--input", required=True, help="OTLP-JSON lines recorded by the lab backend")
    ap.add_argument("--run-id", required=True, help="lab.run_id resource attribute to consume")
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    proposals = propose(args.input, args.run_id)
    for i, p in enumerate(proposals):
        p["id"] = f"P{i}"
    out = {
        "agent": "mock-agent.py (deterministic simulation; not an LLM)",
        "run_id": args.run_id,
        "proposals": proposals,
    }
    with open(args.output, "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=2, sort_keys=True)
        fh.write("\n")
    print(f"mock-agent: {len(proposals)} proposal(s) written to {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
