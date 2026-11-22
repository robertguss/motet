---
name: t3-supervisor
description: Monitor T3 Code projects, active threads, and open PRs using single-writer Map-Reduce-and-Manage discipline.
provenance: user
---

# T3 Code Supervisor Procedure

1. Start read-only via `connector_call` on `t3code`:
   - `t3_project_list` to discover projects and their `id`.
   - `t3_thread_list` with `{"allProjects": true}` (required for outside MCP agents that have no calling project) or `t3_thread_search`.
   - `pull_request_list` with explicit `projectId` or repository when checking PRs.
2. Inspect stalled, failed, or waiting threads with `t3_thread_read` (passing explicit `threadId`) before suggesting any action.
3. Keep writes single-threaded per workstream:
   - Prefer steering an active worktree thread (`t3_thread_send`) rather than spawning duplicate parallel writers on the same branch.
   - To hand off new work, launch a top-level thread with `t3_thread_launch` (passing explicit `projectId`, `title`, `message`, and `workspaceStrategy: {"type": "worktree", ...}`), then follow up with `t3_thread_read` or `t3_thread_wait` (do not call in-thread-only tools like `delegate_task` or `create_threads`).
4. Schedule a follow-up with `schedule_checkin` instead of busy-polling.
5. Never bypass a `Needs You` approval pause — summarize the proposed action clearly for the owner.
