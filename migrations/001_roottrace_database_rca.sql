-- RootTrace Team 3: PostgreSQL schema and deterministic RCA foundation.
-- Apply with psql: psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f migrations/001_roottrace_database_rca.sql

BEGIN;

CREATE TABLE users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email text NOT NULL UNIQUE,
    display_name text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE projects (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL,
    description text,
    created_by uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE project_members (
    project_id uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role text NOT NULL DEFAULT 'member',
    joined_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (project_id, user_id)
);

CREATE TABLE tasks (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    title text NOT NULL,
    description text,
    status text NOT NULL DEFAULT 'open',
    priority text NOT NULL DEFAULT 'medium',
    due_date date,
    created_by uuid REFERENCES users(id) ON DELETE SET NULL,
    assigned_to uuid REFERENCES users(id) ON DELETE SET NULL,
    parent_task_id uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tasks_not_own_parent CHECK (parent_task_id IS DISTINCT FROM id),
    CONSTRAINT tasks_parent_fk FOREIGN KEY (parent_task_id, project_id)
        REFERENCES tasks(id, project_id) DEFERRABLE INITIALLY IMMEDIATE,
    CONSTRAINT tasks_id_project_unique UNIQUE (id, project_id)
);
CREATE INDEX tasks_project_status_idx ON tasks(project_id, status);
CREATE INDEX tasks_parent_idx ON tasks(parent_task_id) WHERE parent_task_id IS NOT NULL;
CREATE INDEX tasks_due_date_idx ON tasks(due_date) WHERE due_date IS NOT NULL;

CREATE FUNCTION prevent_task_parent_cycle() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE has_cycle boolean;
BEGIN
    IF NEW.parent_task_id IS NULL THEN RETURN NEW; END IF;
    WITH RECURSIVE ancestors(id, path) AS (
        SELECT NEW.parent_task_id, ARRAY[NEW.parent_task_id]
        UNION ALL
        SELECT t.parent_task_id, a.path || t.parent_task_id
        FROM ancestors a JOIN tasks t ON t.id = a.id
        WHERE t.parent_task_id IS NOT NULL AND NOT t.parent_task_id = ANY(a.path)
    ) SELECT EXISTS (SELECT 1 FROM ancestors WHERE id = NEW.id) INTO has_cycle;
    IF has_cycle THEN RAISE EXCEPTION 'Task parent relationship would create a cycle'; END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER tasks_prevent_parent_cycle
    BEFORE INSERT OR UPDATE OF parent_task_id ON tasks
    FOR EACH ROW EXECUTE FUNCTION prevent_task_parent_cycle();

CREATE TABLE labels (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    name text NOT NULL,
    color text,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (project_id, name),
    UNIQUE (id, project_id)
);
CREATE TABLE task_labels (
    task_id uuid NOT NULL,
    label_id uuid NOT NULL,
    project_id uuid NOT NULL,
    added_by uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (task_id, label_id),
    FOREIGN KEY (task_id, project_id) REFERENCES tasks(id, project_id) ON DELETE CASCADE,
    FOREIGN KEY (label_id, project_id) REFERENCES labels(id, project_id) ON DELETE CASCADE
);
CREATE INDEX task_labels_label_idx ON task_labels(label_id, task_id);

-- Direction is always source_task_id -> target_task_id. For BLOCKS, source blocks target.
CREATE TABLE task_dependencies (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    source_task_id uuid NOT NULL,
    target_task_id uuid NOT NULL,
    relationship_type text NOT NULL CHECK (relationship_type IN
        ('BLOCKS', 'BLOCKED_BY', 'RELATED_TO', 'CAUSED_BY', 'CONTRIBUTES_TO')),
    created_by uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK (source_task_id <> target_task_id),
    FOREIGN KEY (source_task_id, project_id) REFERENCES tasks(id, project_id) ON DELETE CASCADE,
    FOREIGN KEY (target_task_id, project_id) REFERENCES tasks(id, project_id) ON DELETE CASCADE,
    UNIQUE (source_task_id, target_task_id, relationship_type)
);
CREATE INDEX task_dependencies_out_idx ON task_dependencies(source_task_id, relationship_type, target_task_id);
CREATE INDEX task_dependencies_in_idx ON task_dependencies(target_task_id, relationship_type, source_task_id);

CREATE TABLE task_activities (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    project_id uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    task_id uuid NOT NULL,
    actor_id uuid REFERENCES users(id) ON DELETE SET NULL,
    event_type text NOT NULL CHECK (event_type IN (
        'TASK_CREATED', 'TASK_UPDATED', 'STATUS_CHANGED', 'TASK_ASSIGNED', 'TASK_BLOCKED',
        'DEPENDENCY_ADDED', 'DEPENDENCY_REMOVED', 'LABEL_ADDED', 'LABEL_REMOVED',
        'ROOT_CAUSE_LINKED', 'ROOT_CAUSE_UNLINKED', 'COMMENT_ADDED')),
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    occurred_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (task_id, project_id) REFERENCES tasks(id, project_id) ON DELETE CASCADE
);
CREATE INDEX task_activities_task_time_idx ON task_activities(task_id, occurred_at DESC);
CREATE INDEX task_activities_project_event_idx ON task_activities(project_id, event_type, occurred_at DESC);

-- Keep task changes and relationship edits in structured history automatically.
CREATE FUNCTION audit_task_change() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE ev text; details jsonb;
BEGIN
    IF TG_OP = 'INSERT' THEN
        ev := 'TASK_CREATED';
        details := jsonb_build_object('title',NEW.title,'status',NEW.status,'priority',NEW.priority);
    ELSE
        IF OLD.status IS DISTINCT FROM NEW.status THEN
            ev := 'STATUS_CHANGED';
            details := jsonb_build_object('old_status',OLD.status,'new_status',NEW.status);
        ELSE
            ev := 'TASK_UPDATED';
            details := jsonb_build_object('changed_fields',
                (SELECT coalesce(jsonb_agg(k),'[]'::jsonb) FROM jsonb_each(to_jsonb(NEW)) n(k,v)
                 JOIN jsonb_each(to_jsonb(OLD)) o(k,v) USING(k) WHERE n.v IS DISTINCT FROM o.v));
        END IF;
    END IF;
    INSERT INTO task_activities(project_id,task_id,actor_id,event_type,metadata)
    VALUES (NEW.project_id,NEW.id,NEW.created_by,ev,details);
    IF lower(NEW.status)='blocked' AND (TG_OP='INSERT' OR lower(OLD.status) IS DISTINCT FROM 'blocked') THEN
        INSERT INTO task_activities(project_id,task_id,actor_id,event_type,metadata)
        VALUES (NEW.project_id,NEW.id,NEW.created_by,'TASK_BLOCKED',jsonb_build_object('status',NEW.status));
    END IF;
    IF TG_OP='INSERT' OR OLD.assigned_to IS DISTINCT FROM NEW.assigned_to THEN
        IF NEW.assigned_to IS NOT NULL THEN
          INSERT INTO task_activities(project_id,task_id,actor_id,event_type,metadata)
          VALUES (NEW.project_id,NEW.id,NEW.created_by,'TASK_ASSIGNED',jsonb_build_object('assignee_id',NEW.assigned_to));
        END IF;
    END IF;
    RETURN NEW;
END $$;
CREATE FUNCTION touch_task_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END $$;
CREATE TRIGGER tasks_touch_updated_at BEFORE UPDATE ON tasks
    FOR EACH ROW EXECUTE FUNCTION touch_task_updated_at();
CREATE TRIGGER tasks_audit_changes AFTER INSERT OR UPDATE ON tasks
    FOR EACH ROW EXECUTE FUNCTION audit_task_change();

CREATE FUNCTION audit_dependency_change() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE row_data task_dependencies%ROWTYPE; ev text;
BEGIN
    row_data := CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
    ev := CASE WHEN TG_OP='DELETE' THEN 'DEPENDENCY_REMOVED' ELSE 'DEPENDENCY_ADDED' END;
    INSERT INTO task_activities(project_id,task_id,actor_id,event_type,metadata)
    VALUES (row_data.project_id,row_data.target_task_id,row_data.created_by,ev,
            jsonb_build_object('source_task_id',row_data.source_task_id,'target_task_id',row_data.target_task_id,'relationship_type',row_data.relationship_type));
    RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END $$;
CREATE TRIGGER dependencies_audit_changes AFTER INSERT OR DELETE ON task_dependencies
    FOR EACH ROW EXECUTE FUNCTION audit_dependency_change();

CREATE FUNCTION audit_label_change() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE row_data task_labels%ROWTYPE; ev text;
BEGIN
    row_data := CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
    ev := CASE WHEN TG_OP='DELETE' THEN 'LABEL_REMOVED' ELSE 'LABEL_ADDED' END;
    INSERT INTO task_activities(project_id,task_id,actor_id,event_type,metadata)
    VALUES (row_data.project_id,row_data.task_id,row_data.added_by,ev,jsonb_build_object('label_id',row_data.label_id));
    RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END $$;
CREATE TRIGGER task_labels_audit_changes AFTER INSERT OR DELETE ON task_labels
    FOR EACH ROW EXECUTE FUNCTION audit_label_change();

-- Directed causal graph edge: cause_task_id -> effect_task_id.
CREATE TABLE root_cause_links (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    cause_task_id uuid NOT NULL,
    effect_task_id uuid NOT NULL,
    relationship_type text NOT NULL CHECK (relationship_type IN ('CAUSED_BY', 'CONTRIBUTES_TO')),
    confidence numeric(5,4) NOT NULL DEFAULT 1.0 CHECK (confidence BETWEEN 0 AND 1),
    evidence jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(evidence) = 'array'),
    created_by uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK (cause_task_id <> effect_task_id),
    FOREIGN KEY (cause_task_id, project_id) REFERENCES tasks(id, project_id) ON DELETE CASCADE,
    FOREIGN KEY (effect_task_id, project_id) REFERENCES tasks(id, project_id) ON DELETE CASCADE,
    UNIQUE (cause_task_id, effect_task_id, relationship_type)
);
CREATE INDEX root_cause_links_effect_idx ON root_cause_links(effect_task_id, relationship_type);
CREATE INDEX root_cause_links_cause_idx ON root_cause_links(cause_task_id, relationship_type);

CREATE FUNCTION audit_root_cause_link_change() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE row_data root_cause_links%ROWTYPE; ev text;
BEGIN
    row_data := CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
    ev := CASE WHEN TG_OP='DELETE' THEN 'ROOT_CAUSE_UNLINKED' ELSE 'ROOT_CAUSE_LINKED' END;
    INSERT INTO task_activities(project_id,task_id,actor_id,event_type,metadata)
    VALUES (row_data.project_id,row_data.effect_task_id,row_data.created_by,ev,
      jsonb_build_object('cause_task_id',row_data.cause_task_id,'effect_task_id',row_data.effect_task_id,
                         'relationship_type',row_data.relationship_type,'confidence',row_data.confidence,'evidence',row_data.evidence));
    RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END $$;
CREATE TRIGGER root_cause_links_audit_changes AFTER INSERT OR DELETE ON root_cause_links
    FOR EACH ROW EXECUTE FUNCTION audit_root_cause_link_change();

CREATE TABLE root_cause_hypotheses (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    incident_task_id uuid NOT NULL,
    candidate_task_id uuid NOT NULL,
    score numeric(8,6) NOT NULL CHECK (score >= 0 AND score <= 1),
    confidence numeric(8,6) NOT NULL CHECK (confidence >= 0 AND confidence <= 1),
    supporting_evidence jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(supporting_evidence) = 'array'),
    signals jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(signals) = 'array'),
    status text NOT NULL DEFAULT 'candidate' CHECK (status IN ('candidate', 'accepted', 'rejected', 'superseded')),
    analyzed_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (incident_task_id, project_id) REFERENCES tasks(id, project_id) ON DELETE CASCADE,
    FOREIGN KEY (candidate_task_id, project_id) REFERENCES tasks(id, project_id) ON DELETE CASCADE,
    CHECK (incident_task_id <> candidate_task_id)
);
CREATE INDEX hypotheses_incident_rank_idx ON root_cause_hypotheses(incident_task_id, score DESC);
CREATE INDEX hypotheses_candidate_idx ON root_cause_hypotheses(candidate_task_id, status);

-- Hierarchy: children, descendants, parent and ancestors. Paths guard against legacy cycles.
CREATE FUNCTION task_descendants(p_task_id uuid) RETURNS TABLE(task_id uuid, depth integer, path uuid[])
LANGUAGE sql STABLE AS $$
    WITH RECURSIVE walk(task_id, depth, path) AS (
        SELECT t.id, 1, ARRAY[p_task_id, t.id] FROM tasks t WHERE t.parent_task_id = p_task_id
        UNION ALL
        SELECT t.id, w.depth + 1, w.path || t.id
        FROM walk w JOIN tasks t ON t.parent_task_id = w.task_id
        WHERE NOT t.id = ANY(w.path)
    ) SELECT task_id, depth, path FROM walk
$$;
CREATE FUNCTION task_ancestors(p_task_id uuid) RETURNS TABLE(task_id uuid, depth integer, path uuid[])
LANGUAGE sql STABLE AS $$
    WITH RECURSIVE walk(task_id, depth, path) AS (
        SELECT t.parent_task_id, 1, ARRAY[p_task_id, t.parent_task_id]
        FROM tasks t WHERE t.id = p_task_id AND t.parent_task_id IS NOT NULL
        UNION ALL
        SELECT t.parent_task_id, w.depth + 1, w.path || t.parent_task_id
        FROM walk w JOIN tasks t ON t.id = w.task_id
        WHERE t.parent_task_id IS NOT NULL AND NOT t.parent_task_id = ANY(w.path)
    ) SELECT task_id, depth, path FROM walk
$$;

-- Directed downstream traversal, with path-based cycle protection.
CREATE FUNCTION dependency_downstream(p_task_id uuid, p_relationship_types text[] DEFAULT ARRAY['BLOCKS','BLOCKED_BY'])
RETURNS TABLE(task_id uuid, depth integer, path uuid[])
LANGUAGE sql STABLE AS $$
    WITH RECURSIVE edges(source_id,target_id) AS (
        SELECT CASE WHEN relationship_type='BLOCKED_BY' THEN target_task_id ELSE source_task_id END,
               CASE WHEN relationship_type='BLOCKED_BY' THEN source_task_id ELSE target_task_id END
        FROM task_dependencies WHERE relationship_type = ANY(p_relationship_types)
    ), walk(task_id, depth, path) AS (
        SELECT e.target_id, 1, ARRAY[p_task_id, e.target_id]
        FROM edges e WHERE e.source_id = p_task_id
        UNION ALL
        SELECT e.target_id, w.depth + 1, w.path || e.target_id
        FROM walk w JOIN edges e ON e.source_id = w.task_id
        WHERE NOT e.target_id = ANY(w.path)
    ) SELECT task_id, depth, path FROM walk
$$;
CREATE FUNCTION dependency_upstream(p_task_id uuid, p_relationship_types text[] DEFAULT ARRAY['BLOCKS','BLOCKED_BY'])
RETURNS TABLE(task_id uuid, depth integer, path uuid[])
LANGUAGE sql STABLE AS $$
    WITH RECURSIVE edges(source_id,target_id) AS (
        SELECT CASE WHEN relationship_type='BLOCKED_BY' THEN target_task_id ELSE source_task_id END,
               CASE WHEN relationship_type='BLOCKED_BY' THEN source_task_id ELSE target_task_id END
        FROM task_dependencies WHERE relationship_type = ANY(p_relationship_types)
    ), walk(task_id, depth, path) AS (
        SELECT e.source_id, 1, ARRAY[p_task_id, e.source_id]
        FROM edges e WHERE e.target_id = p_task_id
        UNION ALL
        SELECT e.source_id, w.depth + 1, w.path || e.source_id
        FROM walk w JOIN edges e ON e.target_id = w.task_id
        WHERE NOT e.source_id = ANY(w.path)
    ) SELECT task_id, depth, path FROM walk
$$;

-- Deterministic, explainable candidate ranking. Scores are bounded at 1; the JSON
-- evidence exposes each weighted contribution and the measured signals.
CREATE FUNCTION analyze_root_causes(p_incident_task_id uuid, p_limit integer DEFAULT 20)
RETURNS TABLE(candidate_task_id uuid, candidate_title text, score numeric, confidence numeric,
              chain uuid[], depth integer, supporting_evidence jsonb, signals jsonb)
LANGUAGE sql STABLE AS $$
WITH RECURSIVE
incident AS (SELECT t.* FROM tasks t WHERE t.id = p_incident_task_id),
edges(source_id, target_id, edge_kind, edge_confidence) AS (
    SELECT cause_task_id, effect_task_id, 'explicit'::text, confidence FROM root_cause_links
    UNION ALL
    SELECT CASE WHEN relationship_type IN ('BLOCKED_BY','CAUSED_BY') THEN target_task_id ELSE source_task_id END,
           CASE WHEN relationship_type IN ('BLOCKED_BY','CAUSED_BY') THEN source_task_id ELSE target_task_id END,
           CASE WHEN relationship_type IN ('BLOCKS','BLOCKED_BY') THEN 'blocking' ELSE 'dependency' END,
           CASE WHEN relationship_type IN ('BLOCKS','BLOCKED_BY') THEN 0.75::numeric ELSE 0.25::numeric END
    FROM task_dependencies WHERE relationship_type IN ('BLOCKS','BLOCKED_BY','CAUSED_BY','CONTRIBUTES_TO')
),
walk(candidate_id, current_id, path, depth, explicit_confidence, has_blocking) AS (
    SELECT e.source_id, e.target_id, ARRAY[e.source_id,e.target_id], 1,
           CASE WHEN e.edge_kind = 'explicit' THEN e.edge_confidence ELSE 0 END,
           e.edge_kind = 'blocking'
    FROM edges e JOIN incident i ON i.id=e.target_id
    UNION ALL
    SELECT e.source_id, w.current_id, ARRAY[e.source_id] || w.path, w.depth+1,
           greatest(w.explicit_confidence, CASE WHEN e.edge_kind='explicit' THEN e.edge_confidence ELSE 0 END),
           w.has_blocking OR e.edge_kind='blocking'
    FROM walk w JOIN edges e ON e.target_id=w.candidate_id
    WHERE NOT e.source_id=ANY(w.path) AND w.depth < 100
),
paths AS (
    SELECT DISTINCT ON(candidate_id) candidate_id, path, depth, explicit_confidence, has_blocking
    FROM walk ORDER BY candidate_id, explicit_confidence DESC, depth DESC, cardinality(path) DESC
),
impact AS (
    SELECT p.candidate_id, count(DISTINCT d.task_id)::integer AS downstream_count,
           coalesce(max(d.depth),0)::integer AS max_depth
    FROM paths p LEFT JOIN LATERAL dependency_downstream(p.candidate_id, ARRAY['BLOCKS','BLOCKED_BY']) d ON true
    GROUP BY p.candidate_id
),
recurrence AS (
    SELECT p.candidate_id,
      (SELECT count(DISTINCT h.incident_task_id)::integer FROM root_cause_hypotheses h
       WHERE h.candidate_task_id=p.candidate_id AND h.incident_task_id<>p_incident_task_id AND h.status IN ('candidate','accepted')) AS prior_incidents
    FROM paths p
),
temporal AS (
    SELECT p.candidate_id,
      EXISTS (SELECT 1 FROM task_activities a JOIN incident i ON i.id=p_incident_task_id
              WHERE a.task_id=p.candidate_id AND a.occurred_at < i.created_at) AS precedes_incident
    FROM paths p
),
raw AS (
    SELECT p.*, i.project_id,
      least(0.30::numeric, p.explicit_confidence*0.30) AS explicit_points,
      CASE WHEN p.has_blocking THEN 0.20::numeric ELSE 0 END AS dependency_points,
      least(0.20::numeric, coalesce(im.downstream_count,0)*0.04) AS impact_points,
      least(0.15::numeric, coalesce(r.prior_incidents,0)*0.05) AS recurrence_points,
      CASE WHEN t.precedes_incident THEN 0.10::numeric ELSE 0 END AS temporal_points,
      least(0.05::numeric, coalesce(im.downstream_count,0)*0.01) AS blocking_points,
      coalesce(im.downstream_count,0) AS downstream_count,
      coalesce(im.max_depth,0) AS downstream_depth,
      coalesce(r.prior_incidents,0) AS prior_incidents,
      t.precedes_incident
    FROM paths p JOIN incident i ON true
    LEFT JOIN impact im USING(candidate_id) LEFT JOIN recurrence r USING(candidate_id) LEFT JOIN temporal t USING(candidate_id)
),
scored AS (
    SELECT raw.*, least(1::numeric, explicit_points+dependency_points+impact_points+recurrence_points+temporal_points+blocking_points) AS total
    FROM raw
)
SELECT s.candidate_id, t.title, round(s.total,6), round(s.total,6), s.path, s.depth,
       jsonb_build_array(
         jsonb_build_object('signal','explicit_cause','points',s.explicit_points,'confidence',s.explicit_confidence),
         jsonb_build_object('signal','blocking_dependency','points',s.dependency_points,'present',s.has_blocking),
         jsonb_build_object('signal','downstream_impact','points',s.impact_points,'affected_tasks',s.downstream_count,'deepest_level',s.downstream_depth),
         jsonb_build_object('signal','recurrence','points',s.recurrence_points,'prior_incidents',s.prior_incidents),
         jsonb_build_object('signal','temporal_precedence','points',s.temporal_points,'precedes_incident',s.precedes_incident),
         jsonb_build_object('signal','blocking_impact','points',s.blocking_points,'blocked_tasks',s.downstream_count)),
       jsonb_build_object('explicit_confidence',s.explicit_confidence,'has_blocking_path',s.has_blocking,
                          'downstream_tasks',s.downstream_count,'downstream_depth',s.downstream_depth,
                          'prior_incidents',s.prior_incidents,'precedes_incident',s.precedes_incident)
FROM scored s JOIN tasks t ON t.id=s.candidate_id
ORDER BY s.total DESC, s.explicit_confidence DESC, s.downstream_count DESC, s.depth DESC, t.created_at, t.id
LIMIT greatest(0, least(p_limit, 100))
$$;

-- Builds and persists one analysis run and returns an RCA report as JSON.
CREATE FUNCTION generate_rca_report(p_incident_task_id uuid, p_limit integer DEFAULT 10)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE result jsonb;
BEGIN
    WITH ranked AS MATERIALIZED (SELECT * FROM analyze_root_causes(p_incident_task_id, p_limit)),
    saved AS (
      INSERT INTO root_cause_hypotheses(project_id, incident_task_id, candidate_task_id, score, confidence,
                                         supporting_evidence, signals, analyzed_at)
      SELECT t.project_id, t.id, r.candidate_task_id, r.score, r.confidence,
             r.supporting_evidence, jsonb_build_array(r.signals), now()
      FROM ranked r JOIN tasks t ON t.id=p_incident_task_id
      RETURNING candidate_task_id, score
    )
    SELECT jsonb_build_object(
      'incident', jsonb_build_object('id',i.id,'title',i.title,'status',i.status,'project_id',i.project_id),
      'most_likely_root_cause', (SELECT jsonb_build_object('id',r.candidate_task_id,'title',r.candidate_title,'score',r.score,'confidence',r.confidence) FROM ranked r ORDER BY r.score DESC LIMIT 1),
      'candidates', coalesce((SELECT jsonb_agg(jsonb_build_object('id',r.candidate_task_id,'title',r.candidate_title,'score',r.score,
          'confidence',r.confidence,'chain', (SELECT jsonb_agg(jsonb_build_object('id',ct.id,'title',ct.title) ORDER BY u.ord)
              FROM unnest(r.chain) WITH ORDINALITY u(id,ord) JOIN tasks ct ON ct.id=u.id),
          'depth',r.depth,'downstream_impact',coalesce((r.signals->>'downstream_tasks')::integer,0),
          'evidence',r.supporting_evidence,'signals',r.signals) ORDER BY r.score DESC) FROM ranked r),'[]'::jsonb),
      'affected_tasks', coalesce((SELECT jsonb_agg(jsonb_build_object('id',d.task_id,'title',dt.title,'depth',d.depth) ORDER BY d.depth,dt.title)
          FROM dependency_downstream((SELECT r.candidate_task_id FROM ranked r ORDER BY r.score DESC,r.candidate_task_id LIMIT 1),ARRAY['BLOCKS','BLOCKED_BY']) d
          JOIN tasks dt ON dt.id=d.task_id),'[]'::jsonb),
      'recurring_patterns', coalesce((SELECT jsonb_agg(jsonb_build_object('candidate_task_id',r.candidate_task_id,
          'candidate_title',r.candidate_title,'prior_incidents',(r.signals->>'prior_incidents')::integer) ORDER BY r.score DESC,r.candidate_task_id)
          FROM ranked r WHERE coalesce((r.signals->>'prior_incidents')::integer,0)>0),'[]'::jsonb),
      'activity_history', coalesce((SELECT jsonb_agg(jsonb_build_object('event',a.event_type,'at',a.occurred_at,'metadata',a.metadata) ORDER BY a.occurred_at DESC)
          FROM (SELECT * FROM task_activities WHERE task_id=i.id ORDER BY occurred_at DESC LIMIT 100) a),'[]'::jsonb),
      'generated_at',now()) INTO result
    FROM tasks i WHERE i.id=p_incident_task_id;
    IF result IS NULL THEN RAISE EXCEPTION 'Incident task % not found', p_incident_task_id; END IF;
    RETURN result;
END $$;

-- Aggregation views: API handlers can filter these by project_id.
CREATE VIEW project_health AS
SELECT p.id AS project_id, count(t.id)::bigint AS total_tasks,
       count(t.id) FILTER (WHERE lower(t.status) NOT IN ('done','completed','closed','cancelled'))::bigint AS open_tasks,
       count(t.id) FILTER (WHERE lower(t.status) IN ('done','completed','closed'))::bigint AS completed_tasks,
       count(t.id) FILTER (WHERE t.due_date < current_date AND lower(t.status) NOT IN ('done','completed','closed','cancelled'))::bigint AS overdue_tasks,
       count(t.id) FILTER (WHERE lower(t.status)='blocked')::bigint AS blocked_tasks,
       count(t.id) FILTER (WHERE lower(t.priority) IN ('high','urgent','critical'))::bigint AS high_priority_tasks
FROM projects p LEFT JOIN tasks t ON t.project_id=p.id GROUP BY p.id;

CREATE VIEW dependency_analytics AS
SELECT p.id AS project_id,
       (SELECT count(DISTINCT blocked_id) FROM (
          SELECT target_task_id AS blocked_id FROM task_dependencies WHERE project_id=p.id AND relationship_type='BLOCKS'
          UNION SELECT source_task_id FROM task_dependencies WHERE project_id=p.id AND relationship_type='BLOCKED_BY') b) AS blocked_tasks,
       (SELECT coalesce(jsonb_agg(jsonb_build_object('task_id',x.source_task_id,'title',t.title,'blocked_count',x.n) ORDER BY x.n DESC),'[]'::jsonb)
        FROM (SELECT source_task_id,count(*) n FROM (
                SELECT source_task_id,target_task_id FROM task_dependencies WHERE project_id=p.id AND relationship_type='BLOCKS'
                UNION ALL SELECT target_task_id,source_task_id FROM task_dependencies WHERE project_id=p.id AND relationship_type='BLOCKED_BY') e
              GROUP BY source_task_id ORDER BY n DESC LIMIT 20) x
        JOIN tasks t ON t.id=x.source_task_id) AS most_blocking_tasks,
       (SELECT coalesce(max(depth),0) FROM tasks t CROSS JOIN LATERAL dependency_downstream(t.id,ARRAY['BLOCKS','BLOCKED_BY']) d WHERE t.project_id=p.id) AS deepest_dependency_chain
FROM projects p;

CREATE VIEW rca_analytics_by_project AS
SELECT p.id AS project_id, h.candidate_task_id AS root_cause_task_id, cause.title AS root_cause_title,
       count(DISTINCT h.incident_task_id)::bigint AS incident_count,
       round(avg(h.confidence),6) AS average_confidence,
       count(DISTINCT d.task_id)::bigint AS downstream_impact
FROM projects p JOIN root_cause_hypotheses h ON h.project_id=p.id AND h.status IN ('candidate','accepted')
JOIN tasks cause ON cause.id=h.candidate_task_id
LEFT JOIN LATERAL dependency_downstream(h.candidate_task_id,ARRAY['BLOCKS','BLOCKED_BY']) d ON true
GROUP BY p.id,h.candidate_task_id,cause.title;

CREATE VIEW rca_analytics_by_label AS
SELECT l.project_id,l.id AS label_id,l.name AS label,
       count(DISTINCT h.candidate_task_id)::bigint AS candidate_root_causes,
       count(DISTINCT h.incident_task_id)::bigint AS incident_count,
       round(avg(h.confidence),6) AS average_confidence
FROM labels l JOIN task_labels tl ON tl.label_id=l.id
JOIN root_cause_hypotheses h ON h.candidate_task_id=tl.task_id AND h.status IN ('candidate','accepted')
GROUP BY l.project_id,l.id,l.name;

CREATE VIEW task_status_distribution AS
SELECT project_id,status,count(*)::bigint AS task_count FROM tasks GROUP BY project_id,status;
CREATE VIEW task_trends_daily AS
SELECT project_id,day,
       count(*) FILTER (WHERE event_type='TASK_CREATED')::bigint AS created_count,
       count(*) FILTER (WHERE event_type='STATUS_CHANGED' AND lower(coalesce(metadata->>'new_status','')) IN ('done','completed','closed'))::bigint AS completed_count
FROM (SELECT project_id,event_type,metadata,occurred_at::date AS day FROM task_activities) a
GROUP BY project_id,day;

COMMIT;
