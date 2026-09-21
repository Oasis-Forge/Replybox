---
name: spec
description: Write or extend the product rules for one feature area before building it. Covers what the competitor does, what to learn, and testable rules with stable IDs, and puts the open choices to the user. Use when a roadmap item has no rules yet, or its rules have gaps.
argument-hint: "<feature area>"
---

Feature area: $ARGUMENTS

1. Grep `^## ` in `docs/PRODUCT_RULES.md` and read this area's section, if any, plus the sections its rules will touch. Read the competitor's row and notes in `docs/research/competitor-analysis.md`. Don't re-explore the competitor app unless the user asks. **If that file records that no competitor was studied, skip every step below that depends on one** — and never invent one to fill the shape: a made-up "They do" is worse than none, because the rules that follow would cite it as observed fact.
2. Write the section: **They do** (observed, in our words, "not verified" where partial) → **Learn** (the user need, and where they fall short) → rules. With no competitor, drop **They do** entirely and open with **Learn**, written from the user need itself — what the person is trying to get done, and what makes it tedious today. The rule still has to be testable; it just has nothing to be better *than*. Each rule is testable (a number, a default, an order, an edge case), cites related rules (`see BAL-4`), and keeps the product principles in `CLAUDE.md`. Improve on the competitor; never copy their rule. New IDs continue the area's numbering; never renumber.
3. Check the rules against the rest of the file: counting and totals, deletion and trash, backup and merge, search and export, languages and right-to-left, app lock, permissions (RUN-2), and the privacy policy. Add the missing cross-rules, such as "backups include X".
4. Ask the user only the real choices: AskUserQuestion, at most 4 questions, recommended option first. Record the answers as dated entries under Decisions.
5. Update `docs/ROADMAP.md`: the item cites the new rule IDs. If the data model or build order changes, add it under "Roadmap impact" and put schema steps before the features that read them.
6. Report in at most 5 lines: the section, new rule IDs, and decisions taken. Code comes next, on a branch from a freshly pulled `main`.
