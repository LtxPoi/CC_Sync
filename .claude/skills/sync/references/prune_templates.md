# PRUNE Variant Templates

Reference for the sync skill's `===PRUNE_BEGIN===` block handling. SKILL.md
points here so its main body stays under the published 500-line guidance.
Read this lazily — only when sync.sh's output contains a `===PRUNE_BEGIN===`
block AND you're about to call AskUserQuestion.

Option ordering depends on the `VARIANT` field in the PRUNE block. The four
templates below are pre-validated against AskUserQuestion's schema
(header ≤12 chars, 2-4 options, every option has label+description, question
ends with `?`). Substitute placeholders (`<truncated-label>`, `<LABEL>`,
`<DELETED_AT>`, `<DELETED_REASON>`) from the marker block before sending.

Marker values from sync.sh are **already JSON-escaped** (backslash, double-
quote, `\n` / `\r` / `\t`); interpolate verbatim between `"..."` boundaries,
do NOT re-escape.

## VARIANT: pure-zombie

Local content hash matches ledger; safe to Remove. Remove ordered first.

```json
{"questions": [{"header": "<truncated-label>", "question": "Repo deleted <LABEL> at <DELETED_AT> (\"<DELETED_REASON>\"). Local copy unchanged since last sync — looks like a stale zombie. What to do?", "multiSelect": false, "options": [{"label": "Remove local", "description": "Delete the local file to match the repo's deletion (recommended for pure zombies)"}, {"label": "Keep local", "description": "Keep the file locally but don't push it back; refresh ledger so this prompt stops"}, {"label": "Push back to repo", "description": "Resurrect the file in the repo by overriding the deletion (intentional revival)"}, {"label": "Show content first", "description": "Display the file content, then re-ask"}]}]}
```

## VARIANT: real-conflict

Local hash differs from ledger; possible offline edits. Show first.

```json
{"questions": [{"header": "<truncated-label>", "question": "Repo deleted <LABEL> at <DELETED_AT> (\"<DELETED_REASON>\"), BUT local copy has been edited since last in-sync state. Possible offline work. What to do?", "multiSelect": false, "options": [{"label": "Show content first", "description": "Display the file content to decide whether the offline edits are worth keeping"}, {"label": "Keep local", "description": "Keep the local edits; don't push back; refresh ledger so this prompt stops"}, {"label": "Push back to repo", "description": "Re-add the edited file in the repo, overriding the deletion"}, {"label": "Remove local", "description": "Discard the offline edits and match the repo's deletion (destructive — local edits are lost)"}]}]}
```

## VARIANT: anchor-lost-pure

Ledger entry exists but no matching deletion found in `ledger_sha..HEAD`
(dotfiles history likely rewritten / force-pushed, or the ledger SHA is from
a Keep entry that predates deletion-anchor tracking). Local content still
matches the ledger hash — same posture as pure-zombie. Remove ordered first.

```json
{"questions": [{"header": "<truncated-label>", "question": "Ledger expected <LABEL> in dotfiles but no deletion commit was found and the file is missing — dotfiles history may have been rewritten. Local copy unchanged since last sync. What to do?", "multiSelect": false, "options": [{"label": "Remove local", "description": "Delete the local file to match the repo's current state (recommended for pure zombies after history rewrite)"}, {"label": "Keep local", "description": "Keep the file locally but don't push it back; refresh ledger so this prompt stops"}, {"label": "Push back to repo", "description": "Resurrect the file in the repo (the file then becomes a fresh add against the rewritten history)"}, {"label": "Show content first", "description": "Display the file content, then re-ask"}]}]}
```

## VARIANT: anchor-lost-edited

Ledger entry exists but no deletion commit found AND local hash differs
from ledger — same edited-offline posture as real-conflict. Show first.

```json
{"questions": [{"header": "<truncated-label>", "question": "Ledger expected <LABEL> in dotfiles but no deletion commit was found, AND local copy has been edited since last in-sync state. Possible offline work plus history rewrite. What to do?", "multiSelect": false, "options": [{"label": "Show content first", "description": "Display the file content to decide whether the offline edits are worth keeping"}, {"label": "Keep local", "description": "Keep the local edits; don't push back; refresh ledger so this prompt stops"}, {"label": "Push back to repo", "description": "Re-add the edited file in the repo as a fresh add against the rewritten history"}, {"label": "Remove local", "description": "Discard the offline edits and match the repo's current state (destructive — local edits are lost)"}]}]}
```

## Deferred-read for "Show content first"

Do NOT pre-read the LOCAL file or embed its content as `preview` before the
user picks "Show content first" — the preview field crosses the
AskUserQuestion boundary into the conversation transcript and any tool
logs, and PRUNE-eligible files can include sensitive Claude configuration /
memory / secrets. Match the existing CONFLICT pattern: emit metadata-only
on the first ask, with no `preview` field on any option. Only when the
user selects "Show content first" should you Read the file, then
re-present a fresh AskUserQuestion populated with the just-read content
(the deferred-read pattern that CONFLICT's `--show-diff` opt-in uses).
