# Changelog

## 1.5.0

- Thinking without `maxOutputTokens` sends the model maximum plus the budget instead of 1024 plus the budget. Redacted reasoning is replayed as `redacted_thinking`, unsigned reasoning is dropped with a warning, citations are replayed and empty blocks are no longer produced. Warnings follow upstream order and number formatting; skill provider references resolve to `skill_id`; streams report message ID and model; empty credentials count as absent.
  Compatibility: Source-compatible; changes are additive. Request bodies, results, warnings and errors change to match the reviewed upstream package.
