# Repository Instructions

## Runtime QA Safety

- Treat `~/Library/Application Support/Rex` and related Rex preferences,
  caches, and saved state as user-owned production data.
- Never launch a built Rex bundle or executable directly during automated QA.
  Use `Scripts/run-isolated-rex-smoke.sh`.
- Do not use `open` for smoke tests. Launch Services may reuse a running Rex
  process and therefore bypass the intended test profile.
- Never point `CFFIXED_USER_HOME` at the user's real home directory.
- Diagnostics against user-owned Rex data are metadata-only unless the user
  explicitly authorizes a backup, restore, deletion, or content inspection.
- Never delete or roll back the real Rex profile to clean up a test run.
  Preserve evidence and report the affected paths instead.
