# Ansible Operator Plugins -- Development Guide

## Quick Start

### Prerequisites

- Go 1.26.3 (CI reads the version from `go.mod`)
- Docker with buildx support (for image builds)
- make
- Ansible and ansible-runner (for E2E tests only)

Tool binaries are managed via [bingo](https://github.com/bwplotka/bingo) --
no manual tool installation needed.

### Build and Run

```bash
# Bootstrap dev tools (idempotent, no cluster creation)
make setup

# Build the ansible-operator binary
make build

# Full non-cluster validation (sanity + unit tests)
make verify

# Lint only (no auto-fix)
make lint

# Auto-fix: go mod tidy + go fmt + golangci-lint --fix
make fix

# Regenerate testdata after scaffold template changes
make generate

# Build Docker image
make image-build
```

## Validation Command Matrix

| Change Type | Minimum Validation | Full PR Validation |
|---|---|---|
| Go package code | `go fmt ./path/to/pkg`, `go test ./path/to/pkg`, `go vet ./path/to/pkg` | `make verify` |
| Scaffold/plugin templates | `make generate` + `git diff --exit-code` | `make verify` |
| Go dependencies | `go mod tidy && go mod vendor` | `make verify` |
| Documentation only | Markdown link/render review | `make test-sanity` (for license/format if touching Go-adjacent files) |
| Downstream (openshift/) | `openshift/Makefile` targets | `check-requirements`, `check-collections` |

## Single-File / Focused Change Validation

Go is compiled and type-checked at the **package** level, not the file level.
You cannot validate a single `.go` file in isolation. Always work with the
package containing the file:

```bash
# Format the file (applied to all files in the package)
go fmt ./internal/ansible/controller/

# Run a specific test
go test ./internal/ansible/controller/ -run TestReconcile

# Vet the package
go vet ./internal/ansible/controller/

# Lint the package
golangci-lint run ./internal/ansible/controller/
```

### When Repo-Wide Checks Are Mandatory

- Scaffold template changes (`pkg/plugins/`) -- must run `make generate`
- `go.mod` changes -- must run `go mod tidy && go mod vendor`
- Import path changes in `internal/` or `pkg/`
- Anything touching `hack/generate/`

### Ansible/Python Changes

Molecule test artifacts (`__pycache__/`, `.pytest_cache/`) are gitignored.
E2E molecule tests require `ansible-core` installed:

```bash
pip3 install ansible-core~=2.17.4
make test-e2e-ansible-molecule
```

## Safe Validation Behavior

- `make test-sanity` runs `generate` and `fix` **before** checks, then
  asserts `git diff --exit-code`. This means it may modify files and then
  fail if the working tree becomes dirty.
- E2E tests (`make test-e2e-ansible`) require Docker and Kind. They create a
  cluster, build images, and take several minutes.
- Unit tests run with `-short` flag via `make test-unit`. Tests requiring a
  live cluster are skipped in short mode.

## Build System

### Key Make Targets

| Target | Purpose |
|---|---|
| `make setup` | Bootstrap dev tools via bingo (idempotent) |
| `make verify` / `make check` | Full non-cluster validation (sanity + unit) |
| `make build` | Build the `ansible-operator` binary |
| `make install` | `go install` the binary |
| `make generate` | Rebuild binary, then regenerate all testdata samples |
| `make fix` | `go mod tidy` + `go fmt` + `golangci-lint --fix` |
| `make lint` | Run golangci-lint (no fix) |
| `make test-sanity` | Format, lint, vet, license, error message format, `git diff` |
| `make test-unit` | Unit tests with envtest and `-short` flag |
| `make test-static` | `test-sanity` + `test-unit` |
| `make test-e2e` | Full E2E: Kind cluster, images, all suites |
| `make test-e2e-ansible` | Ansible-specific E2E only |
| `make image-build` | Build Docker image via buildx |
| `make release` | Run goreleaser (snapshot by default) |

### Build Variables

- `CGO_ENABLED=0` is set globally.
- Version info injected via `-ldflags` from `internal/version/version.go`.
  `ImageVersion` (in `version.go`) and `IMAGE_VERSION` (in `Makefile`) must
  be updated together before releases.
- Cross-platform builds use `BUILD_GOOS` and `BUILD_GOARCH` overrides.
- Tool versions managed by bingo in `.bingo/`. Pinned: golangci-lint v1.62.2,
  goreleaser v1.16.2, kind v0.24.0, setup-envtest.

## CI Pipeline

Four GitHub Actions workflows run on every PR:

1. **sanity** (`test-sanity.yml`) -- `make test-sanity`
2. **unit** (`unit.yml`) -- `make test-unit`
3. **ansible** (`test-ansible.yml`) -- `make test-e2e-ansible` + `make test-e2e-ansible-molecule`
4. **release** (`release.yml`) -- goreleaser build + multi-arch Docker image (publishes only on tag push)

All workflows use `go-version-file: "go.mod"`. The `test-docs` target is
currently disabled (missing dependencies).

## Code Conventions

### License Header

Every `.go` file must have an Apache 2.0 license header. Enforced by
`hack/check-license.sh` during `make test-sanity`.

### Error and Log Message Formatting

Enforced by `hack/check-error-log-msg-format.sh`:
- Log messages (Error, Fatal, Info, Warn) must begin with an uppercase letter.
- Error messages (`errors.New`, `fmt.Errorf`) must begin with a lowercase letter.
- Error messages must not end with a period.

### Import Ordering

Three groups separated by blank lines:
1. Standard library
2. Third-party and Kubernetes libraries
3. Internal packages (`github.com/operator-framework/ansible-operator-plugins/...`)

### Logging

Use `logf "sigs.k8s.io/controller-runtime/pkg/log"` with `logf.Log.WithName("...")`.
Verbosity: V(0) for reconciliation lifecycle, V(1) for handler events,
V(2) for request bodies and status events.

### Naming Conventions

- Controllers: `<kind>-<version>-controller` (lowercased)
- Env var overrides: `<SETTING>_<KIND>_<GROUP>` (dots → underscores, uppercased)
- Annotations: prefix `ansible.sdk.operatorframework.io/`
- File permissions: `DirMode = 0755`, `FileMode = 0644`, `ExecFileMode = 0755`

## Vendoring

This project vendors all dependencies. After modifying `go.mod`:

```bash
go mod tidy
go mod vendor
```

Commit the updated `vendor/`. The `make fix` target runs `go mod tidy` but
does not run `go mod vendor`.

## Dependency Management

Dependabot is configured for Docker image dependencies and GitHub Actions.
Go module dependencies are updated manually.

Key dependencies:
- `sigs.k8s.io/controller-runtime` -- controller lifecycle
- `k8s.io/client-go` -- Kubernetes API client
- `github.com/operator-framework/operator-lib` -- predicates, handlers, annotations
- `sigs.k8s.io/kubebuilder/v4` -- plugin framework
- `github.com/prometheus/client_golang` -- metrics
- `github.com/spf13/cobra` + `pflag` + `viper` -- CLI

## Release Process

Releases are tag-driven. See [docs/decisions/adr-0003-release-rebase-workflow.md](decisions/adr-0003-release-rebase-workflow.md) for the full workflow.

1. Update `ImageVersion` in `internal/version/version.go`
2. Update `IMAGE_VERSION` in `Makefile`
3. Run `make generate`
4. Merge the prep PR, then tag

## Downstream / OpenShift

See [docs/references/downstream-sync.md](references/downstream-sync.md) for
the full rebase workflow, `UPSTREAM: <carry|drop>:` convention, and downstream
Make targets.

## Lint Configuration

The repository uses golangci-lint v1.62.2 (pinned via bingo) with a root
`.golangci.yml` configuration. The config enables conservative correctness
linters and excludes `vendor/`, `testdata/`, and `openshift/vendor/`.
