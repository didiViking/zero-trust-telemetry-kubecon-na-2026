# Interface to the zero-trust-telemetry lab. All cluster access goes through lab/lib/common.sh,
# which pins a dedicated kubeconfig (lab/.kube/config) and the context kind-zt-telemetry-lab.
SHELL := /usr/bin/env bash

.PHONY: help lab-up deploy send-telemetry test lab-down status

help:
	@echo "make lab-up          create kind+Cilium+cert-manager+lab PKI (disposable cluster zt-telemetry-lab)"
	@echo "make deploy          deploy gateway, backend and client namespace"
	@echo "make send-telemetry  send synthetic OTLP over mTLS and prove backend receipt"
	@echo "make test            run executable tests (writes evidence/runs/<timestamp>/)"
	@echo "make lab-down        delete ONLY the lab cluster and lab/.kube, lab/.work"
	@echo "make check           static checks, no cluster (shellcheck, yamllint, unit tests, collector config validation)"

lab-up:
	@lab/bootstrap.sh

deploy:
	@lab/deploy.sh

send-telemetry:
	@lab/scripts/send-telemetry.sh

test:
	@tests/run-all.sh

status:
	@lab/scripts/status.sh

lab-down:
	@lab/teardown.sh

# Static checks that need no cluster (the same ones CI's `static` job runs). Requires shellcheck,
# yamllint, docker, kubectl. These check well-formedness only -- they do NOT test any security control.
.PHONY: check
check:
	find . -name '*.sh' -not -path './.git/*' -not -path './lab/.work/*' | xargs shellcheck -x -S warning
	yamllint -c .yamllint.yaml manifests lab scenarios .github .yamllint.yaml
	python3 -I -W error::ResourceWarning examples/tamper-evident/test_chainlog.py
	scenarios/poisoned-log/test.sh --policy-selftest
	lab/scripts/validate-collector-config.sh
