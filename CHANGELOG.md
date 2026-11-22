# Changelog

## 1.5.1

- Align the provider request identity with @ai-sdk/anthropic 4.0.107 after comparing source, declarations and matching-release tests against 4.0.105. Offline validation passed: node Scripts/test-packages.mjs (56 packages, 3672 owning tests and 1760 compatibility tests), generation, tooling, isolation, and version selection. See Docs/Archive/WeeklyUpstreamAudit20261122.md for retained gaps. Paid provider calls were skipped.
  Compatibility: Source-compatible request-header update.
