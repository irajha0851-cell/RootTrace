\set ON_ERROR_STOP on
-- Run against a disposable database after migrations/001_roottrace_database_rca.sql.
-- All fixture rows are rolled back. Any failed assertion aborts the script.
BEGIN;
CREATE TEMP TABLE roottrace_test_results(name text PRIMARY KEY, passed boolean NOT NULL);
CREATE FUNCTION pg_temp.check_test(test_name text, condition boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF condition IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL: %', test_name; END IF;
  INSERT INTO roottrace_test_results VALUES (test_name, true);
END $$;

INSERT INTO users(id,email,display_name) VALUES
 ('10000000-0000-0000-0000-000000000001','rca-test@example.invalid','RCA Test');
INSERT INTO projects(id,name,created_by) VALUES
 ('20000000-0000-0000-0000-000000000001','RCA Test Project','10000000-0000-0000-0000-000000000001'),
 ('20000000-0000-0000-0000-000000000002','Cycle Test Project','10000000-0000-0000-0000-000000000001'),
 ('20000000-0000-0000-0000-000000000003','Empty Project','10000000-0000-0000-0000-000000000001');
INSERT INTO project_members(project_id,user_id,role) VALUES
 ('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','owner');

-- Hierarchy A -> B -> C plus a deeper child.
INSERT INTO tasks(id,project_id,title,created_by) VALUES
 ('30000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','Hierarchy A','10000000-0000-0000-0000-000000000001'),
 ('30000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000001','Hierarchy B','10000000-0000-0000-0000-000000000001'),
 ('30000000-0000-0000-0000-000000000003','20000000-0000-0000-0000-000000000001','Hierarchy C','10000000-0000-0000-0000-000000000001'),
 ('30000000-0000-0000-0000-000000000004','20000000-0000-0000-0000-000000000001','Hierarchy D','10000000-0000-0000-0000-000000000001');
UPDATE tasks SET parent_task_id='30000000-0000-0000-0000-000000000001' WHERE id='30000000-0000-0000-0000-000000000002';
UPDATE tasks SET parent_task_id='30000000-0000-0000-0000-000000000002' WHERE id='30000000-0000-0000-0000-000000000003';
UPDATE tasks SET parent_task_id='30000000-0000-0000-0000-000000000003' WHERE id='30000000-0000-0000-0000-000000000004';
SELECT pg_temp.check_test('hierarchy direct children', (SELECT count(*)=1 FROM task_descendants('30000000-0000-0000-0000-000000000001') WHERE depth=1));
SELECT pg_temp.check_test('hierarchy descendants and depth', (SELECT count(*)=3 AND max(depth)=3 FROM task_descendants('30000000-0000-0000-0000-000000000001')));
SELECT pg_temp.check_test('hierarchy ancestors', (SELECT count(*)=3 AND max(depth)=3 FROM task_ancestors('30000000-0000-0000-0000-000000000004')));
SELECT pg_temp.check_test('root task has no parent or ancestors', (SELECT parent_task_id IS NULL FROM tasks WHERE id='30000000-0000-0000-0000-000000000001') AND (SELECT count(*)=0 FROM task_ancestors('30000000-0000-0000-0000-000000000001')));
DO $$ DECLARE rejected boolean := false; BEGIN
  BEGIN UPDATE tasks SET parent_task_id='30000000-0000-0000-0000-000000000003' WHERE id='30000000-0000-0000-0000-000000000001';
  EXCEPTION WHEN raise_exception THEN rejected := true; END;
  IF NOT rejected THEN RAISE EXCEPTION 'parent cycle was accepted'; END IF;
  INSERT INTO roottrace_test_results VALUES ('parent cycle rejected',true);
END $$;

-- An isolated task exercises no-dependency and no-candidate behavior.
INSERT INTO tasks(id,project_id,title,created_by) VALUES
 ('30000000-0000-0000-0000-000000000005','20000000-0000-0000-0000-000000000001','Isolated incident','10000000-0000-0000-0000-000000000001');
SELECT pg_temp.check_test('task without dependencies', (SELECT count(*)=0 FROM dependency_downstream('30000000-0000-0000-0000-000000000005')));
SELECT pg_temp.check_test('RCA without candidates', (SELECT count(*)=0 FROM analyze_root_causes('30000000-0000-0000-0000-000000000005')));

-- Cycle project: two branches and a dependency cycle. Traversal must terminate without revisiting start.
INSERT INTO tasks(id,project_id,title,created_by) VALUES
 ('31000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000002','Cycle A','10000000-0000-0000-0000-000000000001'),
 ('31000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000002','Cycle B','10000000-0000-0000-0000-000000000001'),
 ('31000000-0000-0000-0000-000000000003','20000000-0000-0000-0000-000000000002','Cycle C','10000000-0000-0000-0000-000000000001');
INSERT INTO task_dependencies(project_id,source_task_id,target_task_id,relationship_type,created_by) VALUES
 ('20000000-0000-0000-0000-000000000002','31000000-0000-0000-0000-000000000001','31000000-0000-0000-0000-000000000002','BLOCKS','10000000-0000-0000-0000-000000000001'),
 ('20000000-0000-0000-0000-000000000002','31000000-0000-0000-0000-000000000001','31000000-0000-0000-0000-000000000003','BLOCKS','10000000-0000-0000-0000-000000000001'),
 ('20000000-0000-0000-0000-000000000002','31000000-0000-0000-0000-000000000002','31000000-0000-0000-0000-000000000003','BLOCKS','10000000-0000-0000-0000-000000000001'),
 ('20000000-0000-0000-0000-000000000002','31000000-0000-0000-0000-000000000003','31000000-0000-0000-0000-000000000001','BLOCKS','10000000-0000-0000-0000-000000000001');
SELECT pg_temp.check_test('dependency branches and cycle terminate', (SELECT count(DISTINCT task_id)=2 AND bool_and(cardinality(path)=depth+1 AND cardinality(path)=(SELECT count(DISTINCT node) FROM unnest(path) node)) FROM dependency_downstream('31000000-0000-0000-0000-000000000001')));
SELECT pg_temp.check_test('dependency upstream', (SELECT count(DISTINCT task_id)=2 FROM dependency_upstream('31000000-0000-0000-0000-000000000001')));
INSERT INTO task_dependencies(project_id,source_task_id,target_task_id,relationship_type,created_by) VALUES
 ('20000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000002','BLOCKED_BY','10000000-0000-0000-0000-000000000001');
SELECT pg_temp.check_test('BLOCKED_BY traversal normalizes blocker direction',
 (SELECT count(*)=1 FROM dependency_downstream('30000000-0000-0000-0000-000000000002') WHERE task_id='30000000-0000-0000-0000-000000000001')
 AND (SELECT count(*)=1 FROM dependency_upstream('30000000-0000-0000-0000-000000000001') WHERE task_id='30000000-0000-0000-0000-000000000002'));
DO $$ DECLARE rejected boolean := false; BEGIN
  BEGIN INSERT INTO task_dependencies(project_id,source_task_id,target_task_id,relationship_type)
    VALUES ('20000000-0000-0000-0000-000000000002','31000000-0000-0000-0000-000000000001','31000000-0000-0000-0000-000000000001','BLOCKS');
  EXCEPTION WHEN check_violation THEN rejected := true; END;
  IF NOT rejected THEN RAISE EXCEPTION 'self dependency was accepted'; END IF;
  INSERT INTO roottrace_test_results VALUES ('self dependency rejected',true);
END $$;
DO $$ DECLARE rejected boolean := false; BEGIN
  BEGIN INSERT INTO task_dependencies(project_id,source_task_id,target_task_id,relationship_type)
    VALUES ('20000000-0000-0000-0000-000000000002','31000000-0000-0000-0000-000000000001','31000000-0000-0000-0000-000000000002','BLOCKS');
  EXCEPTION WHEN unique_violation THEN rejected := true; END;
  IF NOT rejected THEN RAISE EXCEPTION 'duplicate dependency was accepted'; END IF;
  INSERT INTO roottrace_test_results VALUES ('duplicate dependency rejected',true);
END $$;

-- Labels are project-scoped and relationships are many-to-many.
INSERT INTO labels(id,project_id,name) VALUES
 ('40000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','database'),
 ('40000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000001','backend'),
 ('40000000-0000-0000-0000-000000000003','20000000-0000-0000-0000-000000000002','cycle');
INSERT INTO task_labels(task_id,label_id,project_id,added_by) VALUES
 ('30000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001'),
 ('30000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001');
SELECT pg_temp.check_test('task has multiple labels', (SELECT count(*)=2 FROM task_labels WHERE task_id='30000000-0000-0000-0000-000000000001'));
DO $$ DECLARE rejected boolean := false; BEGIN
  BEGIN INSERT INTO labels(project_id,name) VALUES ('20000000-0000-0000-0000-000000000001','database');
  EXCEPTION WHEN unique_violation THEN rejected := true; END;
  IF NOT rejected THEN RAISE EXCEPTION 'duplicate project label was accepted'; END IF;
  INSERT INTO roottrace_test_results VALUES ('duplicate label rejected',true);
END $$;
DO $$ DECLARE rejected boolean := false; BEGIN
  BEGIN INSERT INTO task_labels(task_id,label_id,project_id)
    VALUES ('30000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000003','20000000-0000-0000-0000-000000000001');
  EXCEPTION WHEN foreign_key_violation THEN rejected := true; END;
  IF NOT rejected THEN RAISE EXCEPTION 'cross-project label assignment was accepted'; END IF;
  INSERT INTO roottrace_test_results VALUES ('project-scoped label assignment enforced',true);
END $$;

-- RCA chain: Database -> API -> Authentication -> Login. Login is reported incident.
INSERT INTO tasks(id,project_id,title,status,created_by,created_at) VALUES
 ('32000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','Database pool exhaustion','open','10000000-0000-0000-0000-000000000001',now()-interval '4 days'),
 ('32000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000001','API timeout','open','10000000-0000-0000-0000-000000000001',now()-interval '3 days'),
 ('32000000-0000-0000-0000-000000000003','20000000-0000-0000-0000-000000000001','Authentication failure','open','10000000-0000-0000-0000-000000000001',now()-interval '2 days'),
 ('32000000-0000-0000-0000-000000000004','20000000-0000-0000-0000-000000000001','Login failure','blocked','10000000-0000-0000-0000-000000000001',now()+interval '1 day'),
 ('32000000-0000-0000-0000-000000000005','20000000-0000-0000-0000-000000000001','Unrelated documentation typo','open','10000000-0000-0000-0000-000000000001',now()-interval '1 day'),
 ('32000000-0000-0000-0000-000000000006','20000000-0000-0000-0000-000000000001','Alternative cache issue','open','10000000-0000-0000-0000-000000000001',now()-interval '1 day'),
 ('32000000-0000-0000-0000-000000000007','20000000-0000-0000-0000-000000000001','Historical checkout incident','closed','10000000-0000-0000-0000-000000000001',now()-interval '5 days'),
 ('32000000-0000-0000-0000-000000000008','20000000-0000-0000-0000-000000000001','Tie candidate one','open','10000000-0000-0000-0000-000000000001',now()-interval '1 day'),
 ('32000000-0000-0000-0000-000000000009','20000000-0000-0000-0000-000000000001','Tie candidate two','open','10000000-0000-0000-0000-000000000001',now()-interval '1 day'),
 ('32000000-0000-0000-0000-000000000010','20000000-0000-0000-0000-000000000001','Tie incident','open','10000000-0000-0000-0000-000000000001',now()+interval '1 day');
UPDATE tasks SET status='in_progress' WHERE id='32000000-0000-0000-0000-000000000004';
UPDATE tasks SET status='blocked' WHERE id='32000000-0000-0000-0000-000000000004';
INSERT INTO root_cause_links(project_id,cause_task_id,effect_task_id,relationship_type,confidence,evidence,created_by) VALUES
 ('20000000-0000-0000-0000-000000000001','32000000-0000-0000-0000-000000000001','32000000-0000-0000-0000-000000000002','CAUSED_BY',1,'[{"kind":"operator_report"}]','10000000-0000-0000-0000-000000000001'),
 ('20000000-0000-0000-0000-000000000001','32000000-0000-0000-0000-000000000002','32000000-0000-0000-0000-000000000003','CAUSED_BY',1,'[]','10000000-0000-0000-0000-000000000001'),
 ('20000000-0000-0000-0000-000000000001','32000000-0000-0000-0000-000000000003','32000000-0000-0000-0000-000000000004','CONTRIBUTES_TO',1,'[]','10000000-0000-0000-0000-000000000001'),
 ('20000000-0000-0000-0000-000000000001','32000000-0000-0000-0000-000000000006','32000000-0000-0000-0000-000000000004','CAUSED_BY',0.5,'[{"kind":"alternative"}]','10000000-0000-0000-0000-000000000001'),
 ('20000000-0000-0000-0000-000000000001','32000000-0000-0000-0000-000000000001','32000000-0000-0000-0000-000000000007','CAUSED_BY',1,'[]','10000000-0000-0000-0000-000000000001'),
 ('20000000-0000-0000-0000-000000000001','32000000-0000-0000-0000-000000000008','32000000-0000-0000-0000-000000000010','CAUSED_BY',0.5,'[]','10000000-0000-0000-0000-000000000001'),
 ('20000000-0000-0000-0000-000000000001','32000000-0000-0000-0000-000000000009','32000000-0000-0000-0000-000000000010','CAUSED_BY',0.5,'[]','10000000-0000-0000-0000-000000000001');
INSERT INTO root_cause_links(project_id,cause_task_id,effect_task_id,relationship_type,created_by)
VALUES ('20000000-0000-0000-0000-000000000001','32000000-0000-0000-0000-000000000004','32000000-0000-0000-0000-000000000001','CAUSED_BY','10000000-0000-0000-0000-000000000001');
INSERT INTO task_dependencies(project_id,source_task_id,target_task_id,relationship_type,created_by) VALUES
 ('20000000-0000-0000-0000-000000000001','32000000-0000-0000-0000-000000000001','32000000-0000-0000-0000-000000000002','BLOCKS','10000000-0000-0000-0000-000000000001'),
 ('20000000-0000-0000-0000-000000000001','32000000-0000-0000-0000-000000000002','32000000-0000-0000-0000-000000000003','BLOCKS','10000000-0000-0000-0000-000000000001'),
 ('20000000-0000-0000-0000-000000000001','32000000-0000-0000-0000-000000000003','32000000-0000-0000-0000-000000000004','BLOCKS','10000000-0000-0000-0000-000000000001');
INSERT INTO root_cause_hypotheses(project_id,incident_task_id,candidate_task_id,score,confidence,status)
VALUES ('20000000-0000-0000-0000-000000000001','32000000-0000-0000-0000-000000000007','32000000-0000-0000-0000-000000000001',0.9,0.9,'accepted');
INSERT INTO task_labels(task_id,label_id,project_id,added_by) VALUES
 ('32000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001');
INSERT INTO task_activities(project_id,task_id,actor_id,event_type,metadata) VALUES
 ('20000000-0000-0000-0000-000000000001','32000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000001','COMMENT_ADDED','{"body":"Login errors began after auth failures"}');

SELECT pg_temp.check_test('RCA candidates generated and unrelated excluded',
 (SELECT count(*)>=4 AND bool_and(candidate_task_id<>'32000000-0000-0000-0000-000000000005') FROM analyze_root_causes('32000000-0000-0000-0000-000000000004')));
SELECT pg_temp.check_test('RCA deterministic scores and structured evidence',
 (SELECT score BETWEEN 0 AND 1 AND confidence=score AND jsonb_array_length(supporting_evidence)=6 AND signals ? 'prior_incidents'
  FROM analyze_root_causes('32000000-0000-0000-0000-000000000004') WHERE candidate_task_id='32000000-0000-0000-0000-000000000001'));
SELECT pg_temp.check_test('RCA ranking places recurring upstream database cause first',
 (SELECT candidate_task_id='32000000-0000-0000-0000-000000000001' FROM analyze_root_causes('32000000-0000-0000-0000-000000000004') LIMIT 1));
SELECT pg_temp.check_test('RCA chain has all levels',
 (SELECT chain=ARRAY['32000000-0000-0000-0000-000000000001'::uuid,'32000000-0000-0000-0000-000000000002'::uuid,'32000000-0000-0000-0000-000000000003'::uuid,'32000000-0000-0000-0000-000000000004'::uuid]
  FROM analyze_root_causes('32000000-0000-0000-0000-000000000004') WHERE candidate_task_id='32000000-0000-0000-0000-000000000001'));
SELECT pg_temp.check_test('cyclic causal graph excludes incident and repeats no path nodes',
 NOT EXISTS (SELECT 1 FROM analyze_root_causes('32000000-0000-0000-0000-000000000004') WHERE candidate_task_id='32000000-0000-0000-0000-000000000004')
 AND NOT EXISTS (SELECT 1 FROM analyze_root_causes('32000000-0000-0000-0000-000000000004') r WHERE cardinality(r.chain)<>(SELECT count(DISTINCT x) FROM unnest(r.chain) x)));
SELECT pg_temp.check_test('equal strength alternatives are both returned with equal scores',
 (SELECT count(*)=2 AND min(score)=max(score) FROM analyze_root_causes('32000000-0000-0000-0000-000000000010')
  WHERE candidate_task_id IN ('32000000-0000-0000-0000-000000000008','32000000-0000-0000-0000-000000000009')));
SELECT pg_temp.check_test('generated report includes cause, chain, impact, and history',
 (SELECT report->'most_likely_root_cause'->>'id'='32000000-0000-0000-0000-000000000001'
        AND jsonb_array_length(report->'candidates')>=4
        AND jsonb_array_length(report->'affected_tasks')>=3
        AND jsonb_array_length(report->'recurring_patterns')>=1
        AND jsonb_array_length(report->'activity_history')>0
  FROM (SELECT generate_rca_report('32000000-0000-0000-0000-000000000004') report) r));
SELECT generate_rca_report('32000000-0000-0000-0000-000000000004');
SELECT pg_temp.check_test('repeated reports persist distinct analysis rows', (SELECT count(*)>=8 FROM root_cause_hypotheses WHERE incident_task_id='32000000-0000-0000-0000-000000000004'));
SELECT pg_temp.check_test('label-based RCA analytics', (SELECT count(*)>=1 FROM rca_analytics_by_label WHERE label='database'));
SELECT pg_temp.check_test('project health and empty project aggregation',
 (SELECT total_tasks=0 AND open_tasks=0 FROM project_health WHERE project_id='20000000-0000-0000-0000-000000000003'));
SELECT pg_temp.check_test('activity history contains required structured event types',
 (SELECT count(DISTINCT event_type)>=5 FROM task_activities WHERE project_id='20000000-0000-0000-0000-000000000001'
   AND event_type IN ('TASK_CREATED','STATUS_CHANGED','DEPENDENCY_ADDED','ROOT_CAUSE_LINKED','COMMENT_ADDED')));
SELECT pg_temp.check_test('status change metadata records old and new values',
 (SELECT bool_or(metadata ? 'old_status' AND metadata ? 'new_status') FROM task_activities
   WHERE task_id='32000000-0000-0000-0000-000000000004' AND event_type='STATUS_CHANGED'));
DO $$ DECLARE rejected boolean := false; BEGIN
  BEGIN INSERT INTO root_cause_links(project_id,cause_task_id,effect_task_id,relationship_type)
    VALUES ('20000000-0000-0000-0000-000000000001','32000000-0000-0000-0000-000000000001','32000000-0000-0000-0000-000000000002','CAUSED_BY');
  EXCEPTION WHEN unique_violation THEN rejected := true; END;
  IF NOT rejected THEN RAISE EXCEPTION 'duplicate causal relationship was accepted'; END IF;
  INSERT INTO roottrace_test_results VALUES ('duplicate cause/effect link rejected',true);
END $$;
INSERT INTO tasks(id,project_id,title) VALUES
 ('32000000-0000-0000-0000-000000000011','20000000-0000-0000-0000-000000000001','Disposable task');
INSERT INTO task_dependencies(project_id,source_task_id,target_task_id,relationship_type) VALUES
 ('20000000-0000-0000-0000-000000000001','32000000-0000-0000-0000-000000000011','30000000-0000-0000-0000-000000000005','BLOCKS');
DELETE FROM tasks WHERE id='32000000-0000-0000-0000-000000000011';
SELECT pg_temp.check_test('deleting a referenced task cascades dependent rows',
 NOT EXISTS (SELECT 1 FROM task_dependencies WHERE source_task_id='32000000-0000-0000-0000-000000000011')
 AND NOT EXISTS (SELECT 1 FROM task_activities WHERE task_id='32000000-0000-0000-0000-000000000011'));

SELECT count(*) AS tests_passed, 0 AS tests_failed FROM roottrace_test_results;
SELECT name FROM roottrace_test_results ORDER BY name;
ROLLBACK;
