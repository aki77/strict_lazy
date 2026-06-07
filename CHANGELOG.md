# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-06-07

### Added

- Initial release.
- `include StrictLazy` concern with `lazy_load` declarations (`from:` or block, xor).
- `StrictLazy.preload(records, *readers)` with eager (`sync: true`) and lazy resolution.
- `.lazy` namespace access (`record.lazy.x`) that never grows bare methods.
- Strict detection via `StrictLazy.violation` (`:raise` / `:log` / `:ignore`),
  defaulting to `:raise` in development/test and `:ignore` in production through a Railtie.
- Per-record callable `default:` for unfulfilled records.

[Unreleased]: https://github.com/aki77/strict_lazy/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/aki77/strict_lazy/releases/tag/v0.1.0
