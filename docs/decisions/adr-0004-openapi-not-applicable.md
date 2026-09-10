# ADR-0004: OpenAPI/Swagger Scope Limited to the Metrics API

## Status

Amended (originally "Not Applicable"; revised to document the one stable JSON endpoint)

## Context

An agentic readiness audit flagged the absence of OpenAPI/Swagger specifications
as a gap. The repository contains three internal HTTP servers:

1. **REST proxy** (`internal/ansible/proxy/`) -- intercepts Ansible's K8s API calls
2. **Metrics API** (`internal/ansible/apiserver/`) -- accepts user-defined metrics on `localhost:5050`
3. **Event API** (`internal/ansible/runner/eventapi/`) -- receives ansible-runner events via Unix socket

## Decision

Only the **metrics API** gets an OpenAPI document (`openapi.yaml` at the
repository root). It has a single, stable, authored JSON request schema
(`internal/ansible/metrics.UserMetric`) that is worth describing for tooling
and agents, even though it is local-only (bound to `localhost`, not a public
API).

The proxy and event API are intentionally **not** described in OpenAPI:

- The **proxy** is a pass-through reverse proxy over the full Kubernetes API
  surface -- it has no authored schema of its own to document; the schema is
  Kubernetes' own OpenAPI, already published upstream.
- The **event API** communicates over a Unix domain socket using
  `ansible-runner`'s internal event-stream format, not a request/response
  HTTP contract that OpenAPI models well.

Both remain documented in prose in
[docs/domain/watches-and-contracts.md](../domain/watches-and-contracts.md).

## Consequences

- `openapi.yaml` must be kept in sync with `internal/ansible/metrics/metrics.go`
  whenever the `UserMetric` struct changes.
- The proxy and event API contracts continue to be documented in prose only.
- If a public API surface is ever added, this decision should be revisited.
