# Downstream Synchronization

## Overview

The `openshift/` directory contains an independent build overlay for the
OpenShift downstream fork. It has its own `go.mod`, `vendor/`, `Makefile`,
and `Dockerfile`. Changes to upstream code may require corresponding updates
in this overlay.

For the full human walkthrough of the rebase process, see
[openshift/README.md](../../openshift/README.md).

## UPSTREAM Commit Convention

During downstream rebases, commits use a prefix convention to signal intent:

| Prefix | Meaning | Example |
|---|---|---|
| `UPSTREAM: <drop>:` | Accept upstream version; discard downstream delta on next rebase | Vendor directory refresh |
| `UPSTREAM: <carry>:` | Preserve downstream-specific generated artifact across rebases | ansible_collections update, Cachito requirements |

These prefixes are used by `openshift/hack/rebase_upstream.sh` and are
meaningful during future rebases. Do not add a stock Conventional Commits
validator -- it would reject these legitimate downstream commits.

## Downstream Make Targets

| Target | Purpose |
|---|---|
| `update-collections` | Update Ansible collections in `openshift/release/ansible/` |
| `generate-requirements` | Regenerate downstream requirements files |
| `check-requirements` | Validate downstream requirements are consistent |
| `check-collections` | Validate Ansible collections are up to date |

## What to Edit Upstream vs. Downstream

| Change | Where |
|---|---|
| Go source code, controller logic | Root (`internal/`, `pkg/`, `cmd/`) |
| Scaffold templates | `pkg/plugins/ansible/v1/scaffolds/` |
| Go dependencies | Root `go.mod` + `vendor/` |
| OpenShift-specific build config | `openshift/` |
| Ansible collections | `openshift/release/ansible/` (via rebase script) |
| Downstream Go dependencies | `openshift/go.mod` + `openshift/vendor/` |
| CI operator config | `.ci-operator.yaml` |

## Downstream Ownership

- `DOWNSTREAM_OWNERS` and `DOWNSTREAM_OWNERS_ALIASES` control review permissions for the OpenShift fork.
- `.ci-operator.yaml` configures the OpenShift CI build root image.
