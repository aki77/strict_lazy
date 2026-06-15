# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Nested preload: `StrictLazy.preload` now accepts a Rails-style spec, so lazy
  values on associated records can be prepared in one call —
  `StrictLazy.preload(posts, :comments_count, comments: [:reply_count, { replies: :shout }])`.
  Associations are batch-loaded to avoid N+1; nesting is arbitrarily deep.

### Changed

- `StrictLazy.preload` groups records by STI base class, so a mixed-class array
  (STI subtrees, or children gathered across associations) resolves each loader
  once per declaring class. Single-model calls are unchanged.

## [0.3.0] - 2026-06-14

### Added

- `StrictLazy.with_violation(mode) { ... }` — scope the violation policy to a
  block, restoring the previous state afterward (exception-safe). Overrides
  nest and are isolated per Fiber/Thread, so parallel test processes never
  interfere. Useful for relaxing the policy per test type, e.g. `:ignore` in
  model specs while keeping `:raise` in system specs.
- `StrictLazy.violation=` and `with_violation` now raise `ArgumentError` for
  modes other than `:raise` / `:log` / `:ignore`.

### Changed

- `StrictLazy.violation` is now a reader that returns the **effective** policy
  for the current execution context (the innermost `with_violation` override,
  else the global baseline). The global baseline moved to
  `StrictLazy.default_violation`; `StrictLazy.violation=` still sets it, so the
  public API and the Railtie are unchanged.

## [0.2.0] - 2026-06-14

### Added

- Support predicate reader names (`lazy_load :published?`), read via
  `record.lazy.published?`. A reader must be a bare name or a `?` predicate; the
  read-only `.lazy` namespace rejects setter (`=`), bang (`!`), and operator
  reader names at declaration time.

## [0.1.0] - 2026-06-07

### Added

- Initial release.
- `include StrictLazy` concern with `lazy_load` declarations (`from:` or block, xor).
- `StrictLazy.preload(records, *readers)` with eager (`sync: true`) and lazy resolution.
- `.lazy` namespace access (`record.lazy.x`) that never grows bare methods.
- Strict detection via `StrictLazy.violation` (`:raise` / `:log` / `:ignore`),
  defaulting to `:raise` in development/test and `:ignore` in production through a Railtie.
- Per-record callable `default:` for unfulfilled records.

[Unreleased]: https://github.com/aki77/strict_lazy/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/aki77/strict_lazy/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/aki77/strict_lazy/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/aki77/strict_lazy/releases/tag/v0.1.0
