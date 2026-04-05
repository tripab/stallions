# AGENT_LOG.md — Schema

## Phases & Worktrees
| Phase | Name | Worktree Path | Branch | Status |
|-------|------|---------------|--------|--------|
| 1 | Foundation | .worktrees/phase-1-foundation | phase/1-foundation | Active |
| 2 | Networking | .worktrees/phase-2-networking | phase/2-networking | Pending |

## Task Index
| ID       | Title                         | Phase | Status    | Depends On | Tags              |
|----------|-------------------------------|-------|-----------|------------|-------------------|
| TASK-001 | Project scaffold & structure  | 1     | Pending   | —          | backend, infra    |
| TASK-002 | Network layer base client     | 2     | Pending   | TASK-001   | backend.api       |

Valid statuses: Pending → In Review → Reviewed → In Review → Approved → Done

Tags: comma-separated, dot-separated hierarchy (e.g. `backend.api.auth`). Routing uses prefix matching — a role with tag `backend` also claims tasks tagged `backend.api`, `backend.api.auth`, etc. The wildcard `*` matches any tag. Tasks with no tags can be claimed by any implementer-type agent (v2 compatibility).

## Agent Activity Log
<!-- Append-only. One line per event. -->
- [YYYY-MM-DD HH:MM] <Agent>: <action>
