# ADR 0002: Metadata must not break user code

- Status: Accepted
- Date: 2026-04-29
- Related: [FR-M-1](../FUNCTIONAL_SPEC.md#51-metadata-content-fr-m), [Section 3 Hard Constraints](../FUNCTIONAL_SPEC.md#3-hard-constraints), [native-build-tools interface contract](../FUNCTIONAL_SPEC.md#47-consumption-by-native-build-tools)

## Context

Application developers consume this repository indirectly: the GraalVM Gradle / Maven plugins resolve metadata for every dependency in their build and pass it to `native-image`. The user neither sees the metadata nor opts into individual entries — every artifact resolution is implicit.

That makes correctness *asymmetric*. A missing metadata entry surfaces as a recognizable `native-image` runtime error the user can diagnose; a metadata entry that *changes program behavior* surfaces as a silent miscompilation, an unexpected initialization order, or arbitrary code executing at the user's build time. The first failure mode is recoverable, the second is not.

To stay safe under that asymmetry, the metadata this repository ships must be **purely additive** with respect to a user's program: it can only register reflection / JNI / resource / serialization / proxy targets that `native-image` would otherwise miss. It must not change *how* the user's classes initialize, *what* code runs at image-build time, or *which* bytecode the user is actually running.

Two properties make additivity achievable in practice:

1. **Metadata format additivity.** The reachability-metadata schema only describes registrations conditioned on `typeReachable` (FR-M-2). An entry that names a class never reached in the user's program has no effect; an entry that names a reached class only enables an access pattern `native-image` already had to support at runtime.
2. **`native-image` guarantees.** Runtime initialization is the default and is enforced by the absence of `native-image.properties` (FR-M-1). Without build-time-initialization directives, a metadata bundle cannot move user classes into the image-build classloader or alter their initialization order.

GraalVM `native-image` also exposes mechanisms that *do* let configuration alter user code — build-time class initialization, library patching via substitutions, and `Feature` classes that run arbitrary Java at image-build time. Each of these breaks additivity:

- **Build-time-initialization tweaks** (e.g., `--initialize-at-build-time` in `native-image.properties`) move class `<clinit>` execution into the image builder. The user's class is then initialized in an environment that is not their JVM, and any state it captures (timestamps, locales, env vars, static singletons) becomes baked into the image. The user did not opt into that and cannot easily undo it.
- **Patching libraries themselves** (substitutions, bytecode rewrites) ships a *different version* of the library than the one the user resolved through Maven Central. The user reads upstream sources but runs our fork; behavioral drift is invisible at the dependency-resolution layer and is unstable across upstream releases.
- **`Feature` classes** are arbitrary Java executed inside the image builder with full filesystem, network, and reflective access. They are a security concern (a metadata bundle could now exfiltrate or tamper) and break additivity because their effect is whatever code the author wrote.

## Decision

Metadata published from this repository must not change the observable behavior of the user's program when consumed through native-build-tools. Concretely, the repository's hard constraints are:

1. **Runtime initialization only.** No metadata bundle may ship `native-image.properties` or any other build-time-initialization directive (FR-M-1). Every library is runtime-initialized.
2. **No library patching.** No substitutions, bytecode rewrites, or shaded forks of upstream libraries. The user runs the bytecode they resolved.
3. **No `Feature` classes.** No metadata bundle may ship a `org.graalvm.nativeimage.hosted.Feature` implementation or any other artifact that executes Java inside the image builder.
4. **`typeReachable` on every entry.** All registrations are conditional on a class inside the artifact's `allowed-packages` (FR-M-2, FR-M-3) so that an entry has no effect on programs that do not reach the conditioning class.

These constraints apply uniformly to human-authored PRs and to Metadata Forge output, and are enforced by `checkMetadataFiles` plus reviewer skills.

## Consequences

- The contract with native-build-tools users — *adding this repository to your build never changes how your code runs* — is preserved. Failures degrade to "missing metadata" reports, never silent miscompilation.
- Some libraries that would only work under `--initialize-at-build-time` cannot be supported in this repository as-is. The remediation is upstream: the library makes itself runtime-initialization-safe, after which we add metadata. Shipping the build-time-initialization tweak ourselves is rejected as out-of-scope by this ADR, not as a per-PR decision.
- Bug-for-bug parity with broken upstream library code stays the user's problem (or upstream's), not ours. We cannot patch around it.
- Generation pipelines (Forge) cannot use `Feature`-based scaffolding to "make tests pass"; they have to produce metadata that works under the same additive contract that human contributors are bound by.
- Reviewers can reject any PR that introduces `native-image.properties`, substitutions, or `Feature` classes by citing this ADR, without re-litigating the underlying tradeoff.

## Alternatives considered

- **Allow `native-image.properties` for libraries that genuinely need build-time initialization.** Rejected: the user has no signal that adding our repository changed their initialization order, and the change is global to their image. Every exception erodes the "purely additive" guarantee that the rest of the catalog relies on.
- **Allow scoped substitutions to patch known-broken upstream releases.** Rejected: a substitution makes us a soft fork of upstream, with all the maintenance cost and divergence risk that implies, and the user still reads upstream sources while running ours.
- **Allow `Feature` classes for advanced registration.** Rejected: arbitrary code at image-build time is a security boundary we are not willing to cross for metadata distribution. Anything a `Feature` can express is also expressible as conditional reachability metadata or belongs upstream in `native-image` itself.
