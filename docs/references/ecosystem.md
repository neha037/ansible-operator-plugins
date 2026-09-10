# Ecosystem References

## Operator SDK

- [operator-framework/operator-sdk](https://github.com/operator-framework/operator-sdk) -- the parent project consuming this plugin
- [operator-framework/operator-lib](https://github.com/operator-framework/operator-lib) -- predicates, instrumented handlers, owner annotations

## Kubernetes and Controller Runtime

- [controller-runtime](https://pkg.go.dev/sigs.k8s.io/controller-runtime) v0.21.0 -- controller lifecycle, manager, cache, client
- [kubebuilder](https://pkg.go.dev/sigs.k8s.io/kubebuilder/v4) v4.6.0 -- plugin framework for scaffolding
- [client-go](https://pkg.go.dev/k8s.io/client-go) -- Kubernetes API client, discovery, rest config

## Build and Tooling

- [bingo](https://github.com/bwplotka/bingo) -- pinned tool version management (`.bingo/` directory)
- [goreleaser](https://goreleaser.com/) -- release automation
- [golangci-lint](https://golangci-lint.run/) v1.62.2 -- linting (pinned via bingo)

## Ansible

- [ansible-runner](https://ansible-runner.readthedocs.io/) -- subprocess interface for running playbooks/roles
- Ansible collections for Kubernetes: `kubernetes.core`, `operator_sdk.util`

## Container Images

- `quay.io/operator-framework/ansible-operator` -- published operator base image
- `images/ansible-operator/` -- Dockerfile and Pipfile for the operator image
