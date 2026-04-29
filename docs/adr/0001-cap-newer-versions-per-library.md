# ADR 0001: Cap newer versions per library at 30 in `verify-new-library-version-compatibility`

- Status: Accepted
- Date: 2026-04-29
- Related: [FR-CI-5](../FUNCTIONAL_SPEC.md#54-ci-gates-fr-ci), [CI.md `verify-new-library-version-compatibility`](../CI.md), [`generateNewLibraryVersionCompatibilityMatrix`](../../tests/tck-build-logic/src/main/groovy/org.graalvm.internal.tck-harness.gradle)

## Context

The scheduled `verify-new-library-version-compatibility` workflow (every 8 hours and on `workflow_dispatch`) discovers libraries whose upstream has released versions newer than the latest entry under `tested-versions`. For each such library, every newer version is then expanded across the configured GraalVM JDK / OS combinations in `ci.json`, producing a matrix entry per `(library, version, jdk, os)`.

When a library has been dormant on our side and upstream has shipped many releases — or when several libraries simultaneously have long backlogs — the unbounded expansion produces matrix sizes that:

- exceed GitHub Actions per-job and per-workflow time budgets, causing scheduled runs to time out before completing;
- starve runners shared with PR-gating workflows, delaying contributor feedback;
- generate large bursts of failure issues that obscure the few signals that actually matter (the next failing version per library).

## Decision

Each scheduled run of `verify-new-library-version-compatibility` is capped at **at most 30 newer versions per library** before the JDK/OS expansion. Versions are taken in upstream release order (oldest-newer first), so the next run picks up where the previous one left off after a passing version is recorded under `tested-versions`.

The 30 cap sits alongside, and is independent of, the per-run **library budget**, which limits how many libraries enter the matrix at all.

## Consequences

- Worst-case matrix size per library is bounded, so scheduled runs finish within GitHub Actions limits and do not time out.
- Libraries with very large backlogs are caught up over multiple scheduled runs rather than in a single oversized run; this is acceptable because the workflow runs every 8 hours and each successful version is recorded incrementally.
- The cap is a workflow-level guardrail, not a correctness boundary: changing it does not change which versions are eligible, only how many are attempted per run.
- If GitHub Actions limits change, runner capacity changes, or the test surface per `(library, version)` changes materially, this ADR should be revisited and the constant updated in [`generateNewLibraryVersionCompatibilityMatrix`](../../tests/tck-build-logic/src/main/groovy/org.graalvm.internal.tck-harness.gradle).

## Alternatives considered

- **No cap, rely on the per-run library budget alone.** Rejected: a single library with a long backlog can still exhaust the per-job time budget, which is what we observed in practice.
- **Cap by total matrix size across libraries.** Rejected: one noisy library would crowd out all other libraries in the same run, slowing recovery for the rest of the catalog.
- **Cap by wall-clock budget per library.** Rejected: harder to reason about, harder to test, and provides no determinism for matrix planning.
