---
name: code-review
description: Perform a clean-context read-only review of a diff or repository state and save a concise artifact.
provenance: user
---

# Clean-Context Review Procedure

1. Read only the changed files and test output (`file_read`, `cmd_run` with `git diff` / `mo check` / `mo test`).
2. Prioritize correctness bugs, security/capability regressions, and missing edge-case tests over style nits.
3. Save the structured review using `artifact_save` (`kind: "report"`) and record recurring patterns to bot memory.
