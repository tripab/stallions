# AGENT_LOG.md — Schema

## Phases & Worktrees
| Phase | Name | Worktree Path | Branch | Status |
|-------|------|---------------|--------|--------|
| 1 | Foundation | .worktrees/phase-1-foundation | phase/1-foundation | Active |
| 2 | Networking | .worktrees/phase-2-networking | phase/2-networking | Pending |

## Task Index
| ID | Title | Phase | Status | Depends On |
|----------|-------------------------------|-------|-----------|------------|
| TASK-001 | Project scaffold & structure | 1 | Pending | — |
| TASK-002 | Network layer base client | 2 | Pending | TASK-001 |

Valid statuses: Pending → In Review → Reviewed → In Review → Approved → Done

## Agent Activity Log
<!-- Append-only. One line per event. -->
- [YYYY-MM-DD HH:MM] <Agent>: <action>
