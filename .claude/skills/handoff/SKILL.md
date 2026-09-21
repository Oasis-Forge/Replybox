---
name: handoff
description: Rewrite the session-handoff memory as a short note (where work stopped, the next step, what waits on the user) so the next session resumes cheaply. Use at the end of a session, after a PR merges, or before compacting.
---

This stays in the main session: only it knows what happened.

Replace the whole `session-handoff` memory file in the memory directory (don't append to it) with this form, at most 25 lines:

```markdown
---
name: session-handoff
description: where work stopped on YYYY-MM-DD; read on "resume"
metadata:
  type: project
---

**Stopped:** date; branch and its state (PR number, CI, merged or waiting on the user).
**Next:** the one next step, specific enough to start without asking.
**Waiting on the user:** questions or approvals asked and not answered yet.
**Loose ends:** anything left on disk, on a device, or on GitHub.
```

Leave out:
- Anything git log, `CHANGELOG.md`, or `docs/ROADMAP.md` already records, and anything finished.
- How-tos and lessons. A lesson worth keeping goes into its own feedback memory (update the one that already covers it) and gets a `[[link]]` here, not a paragraph.

Then update the date in its `MEMORY.md` line.
