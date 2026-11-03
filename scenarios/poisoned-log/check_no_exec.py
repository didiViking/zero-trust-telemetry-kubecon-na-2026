#!/usr/bin/env python3
"""Static check (AST, so comments/docstrings are irrelevant): the scenario's components must be
incapable of executing telemetry text. Fails on imports of process/dynamic-code modules and on calls
to eval/exec/compile/__import__. Exit 0 = clean, 1 = violation(s) found."""
import ast
import sys

BANNED_MODULES = {"subprocess", "os", "pty", "shlex", "ctypes", "importlib", "runpy", "code", "socket"}
BANNED_CALLS = {"eval", "exec", "compile", "__import__", "open_code"}


def violations(path):
    with open(path, encoding="utf-8") as fh:
        tree = ast.parse(fh.read(), filename=path)
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for a in node.names:
                if a.name.split(".")[0] in BANNED_MODULES:
                    yield f"{path}:{node.lineno}: import {a.name}"
        elif isinstance(node, ast.ImportFrom):
            if (node.module or "").split(".")[0] in BANNED_MODULES:
                yield f"{path}:{node.lineno}: from {node.module} import ..."
        elif isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in BANNED_CALLS:
            yield f"{path}:{node.lineno}: call to {node.func.id}()"


def main():
    found = [v for p in sys.argv[1:] for v in violations(p)]
    for v in found:
        print(v)
    sys.exit(1 if found else 0)


if __name__ == "__main__":
    main()
