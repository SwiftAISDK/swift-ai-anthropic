# Changelog

## 1.4.0

- Distinguish dated base Fable 5 from genuine 5.1/5.2 aliases, retaining the original hosted JSON-tool fallback and minor-model native-output controls. Add nullable typed extraction through Messages, splitting at 16 fields with shared cancellation. Claude Fable 5.2 follows the current adaptive-thinking, sampling-warning and forced-tool fallback policies. Reviewed npm delta: @ai-sdk/anthropic 4.0.99 to 4.0.104. Validation: `node Scripts/test-packages.mjs` passed all 52 owning suites and 1731 facade tests; tooling 27/27, generation/isolation checks, standalone exports and 106 minimum/latest consumers, documentation check and 101-page build passed. Publication requires green exact-source Swift 6.3.3 CI. Paid/live verification and full-package parity are not claimed.
  Compatibility: Additive native APIs or capabilities under the project minor-release convention. npm baselines and Swift SemVer are independent; this reviewed delta does not establish full-package or live-service parity. Required direct minimums: swift-ai-core 1.3.0 to 1.4.0.
