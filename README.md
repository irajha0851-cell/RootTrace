# RootTrace database and RCA foundation

This workspace had no existing application or database code, so the Team 3 implementation is a PostgreSQL migration that can be integrated with a future API without choosing a backend framework.

## Setup and test

Expected PostgreSQL version: **13 or later**. The migration uses `gen_random_uuid()` (built in on these versions), JSONB, recursive CTEs, SQL/PLpgSQL functions, and filtered aggregates. Use a disposable database for the test script; it inserts fixed-ID fixtures inside a transaction and rolls them back.

Create a database (using a role allowed to create databases):

```powershell
psql -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE roottrace;"
```

Apply the migration:

```powershell
psql -d roottrace -v ON_ERROR_STOP=1 -f migrations/001_roottrace_database_rca.sql
```

Run the standalone SQL assertions:

```powershell
psql -d roottrace -v ON_ERROR_STOP=1 -f tests/database_rca_test.sql
```

On success, the final summary row reports the number of passed assertions and `0` failures, followed by their names. A failing assertion raises an error and stops `psql`; the script does not print a success summary. I could not execute this suite in the current workspace because `psql`, a PostgreSQL server, and Docker are unavailable here.

## Main entry points

- `task_descendants(task_id)` and `task_ancestors(task_id)` return hierarchy paths and depths. Parent changes are constrained to the same project and a trigger prevents cycles.
- `dependency_downstream(task_id, types)` and `dependency_upstream(task_id, types)` traverse blocking relationships. The default includes `BLOCKS` and `BLOCKED_BY`, normalizing both to blocker -> blocked task. Each returned path prevents revisiting a node if data contains a cycle. Dependency cycles are allowed by storage, but traversal terminates safely.
- `analyze_root_causes(incident_task_id, limit)` ranks actual upstream candidates with bounded, configurable-by-source weights and JSON signal explanations. The current constants are centralized in that function: explicit cause (0.30), blocking dependency (0.20), impact (up to 0.20), recurrence (up to 0.15), temporal precedence (0.10), and blocking impact (up to 0.05).
- `generate_rca_report(incident_task_id, limit)` persists structured hypotheses and returns a JSON report with ranked candidates, chains, downstream tasks, and activity history.
- `project_health`, `dependency_analytics`, `rca_analytics_by_project`, `rca_analytics_by_label`, `task_status_distribution`, and `task_trends_daily` provide SQL aggregations for API use.

Task edits and task, dependency, label, and causal-link insertions/removals are recorded by database triggers in `task_activities`. Activity metadata is JSONB. Task status changes include both old and new status values.

For `BLOCKS`, `source_task_id` blocks `target_task_id`; for `BLOCKED_BY`, `source_task_id` is blocked by `target_task_id`. Traversal normalizes these directions. `root_cause_links` separately models cause -> effect edges. The RCA analysis is deterministic and does not use an LLM. Score and confidence are deterministic ranking values rather than calibrated probabilities.

Example RCA query:

```sql
SELECT jsonb_pretty(generate_rca_report('00000000-0000-0000-0000-000000000001', 10));
```

The returned JSON has this shape (values depend on stored data):

```json
{
  "incident": {"id": "...", "title": "Login failure", "status": "blocked", "project_id": "..."},
  "most_likely_root_cause": {"id": "...", "title": "Database pool exhaustion", "score": 0.8, "confidence": 0.8},
  "candidates": [{"id": "...", "title": "Database pool exhaustion", "score": 0.8,
    "chain": [{"id": "...", "title": "Database pool exhaustion"}, {"id": "...", "title": "API timeout"}],
    "depth": 3, "downstream_impact": 3, "evidence": [], "signals": {}}],
  "affected_tasks": [{"id": "...", "title": "API timeout", "depth": 1}],
  "recurring_patterns": [{"candidate_task_id": "...", "candidate_title": "Database pool exhaustion", "prior_incidents": 3}],
  "activity_history": [],
  "generated_at": "..."
}
```

## Integration notes

The schema includes a minimal `users` table because no existing authentication/user model was present. An application can map its identity provider IDs to these UUIDs or adapt the foreign keys during integration. The database intentionally does not prescribe API routes, status/priority vocabularies beyond the conventions used in analytics, or a migration runner. A task supports one optional parent, not multiple parents; it can have multiple dependency edges.
