---
name: review-diff
description: Review the current code change (git diff) using the code-reviewer agent, tailored to the Waymark FSD-Benchmark repo. Use before committing, or when the user says "review my changes", "review the diff", "review this before I commit". Reports correctness bugs and quality issues; does not edit or commit.
---

# review-diff

Run a focused, read-only review of the current change set before it gets committed.

## Steps

1. **Scope the diff.** Unless the user specifies a base ref or files, review the working-tree changes:
   - `git --no-pager diff --stat HEAD` to see what changed
   - if nothing is uncommitted, fall back to the most recent commit: `git --no-pager show --stat HEAD`
   - if there is genuinely nothing to review, tell the user and stop.

2. **Delegate to the reviewer.** Launch the `code-reviewer` agent (subagent_type: `code-reviewer`) with
   the scope you determined. Ask it to review the diff against this repo's rules: contract fidelity
   (`contracts/openapi.yaml`, `contracts/mapmatch.py`), idempotency, unit/type correctness,
   ports-faked-seams-real, ownership boundaries (Person C's lane), secrets hygiene, and TDD coverage.
   - Prefer continuing an existing `code-reviewer` agent via SendMessage if one is already running.

3. **Relay the findings.** Present the agent's report to the user, most-severe first. Do NOT auto-apply
   fixes — this skill is review-only. If the user then asks to fix something, address the specific
   findings they choose.

## Notes

- Read-only: never commit, never force-push, never edit as part of the review itself.
- This complements the built-in `/code-review` skill; use this one for the repo-tailored, agent-driven
  review keyed to the Person C / M1 contracts.
