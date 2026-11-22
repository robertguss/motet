---
name: t3-supervisor
description: Monitor T3 Code projects, active threads, and open PRs using single-writer Map-Reduce-and-Manage discipline.
provenance: user
---

# T3 Code Supervisor Procedure

1. Start read-only: call `connector_call` on `t3code` with `t3_project_list`, `t3_thread_list`, and `pull_request_list`.
2. Inspect stalled, failed, or waiting threads with `t3_thread_read` before suggesting any action.
3. Keep writes single-threaded per workstream:
   - Prefer steering an active worktree thread (`t3_thread_send`) rather than spawning duplicate parallel writers on the same branch.
   - When launching a new engineering workstream (`t3_thread_launch`), give it a crisp goal, acceptance criteria, and a dedicated worktree.
4. Schedule a follow-up with `schedule_checkin` instead of busy-polling.
5. Never bypass a `Needs You` approval pause — summarize the proposed action clearly for the owner.
