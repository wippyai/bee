UPDATE workspaces SET root_ref = 'bee.env:workspace_root'
WHERE root_ref = 'bee.environment:workspace_root';
UPDATE workspace_application_thread_bindings SET definition_id = CASE definition_id
    WHEN 'bee.hive_manager:app' THEN 'bee.hive.manager:app'
    WHEN 'bee.inbox:app' THEN 'bee.approvals.inbox:app'
    WHEN 'bee.modules:app' THEN 'bee.hub.modules:app'
    WHEN 'bee.overlays:app' THEN 'bee.gov.overlays:app'
    WHEN 'bee.workspaces:app' THEN 'bee.workspace.manager:app'
    WHEN 'bee.timeline:app' THEN 'bee.threads.timeline:app'
    WHEN 'bee.processes:app' THEN 'bee.host.processes:app'
    ELSE definition_id END;
UPDATE workspace_state SET value =
    replace(replace(replace(replace(replace(replace(replace(value,
    '"definition_id":"bee.hive_manager:app"', '"definition_id":"bee.hive.manager:app"'),
    '"definition_id":"bee.inbox:app"', '"definition_id":"bee.approvals.inbox:app"'),
    '"definition_id":"bee.modules:app"', '"definition_id":"bee.hub.modules:app"'),
    '"definition_id":"bee.overlays:app"', '"definition_id":"bee.gov.overlays:app"'),
    '"definition_id":"bee.workspaces:app"', '"definition_id":"bee.workspace.manager:app"'),
    '"definition_id":"bee.timeline:app"', '"definition_id":"bee.threads.timeline:app"'),
    '"definition_id":"bee.processes:app"', '"definition_id":"bee.host.processes:app"')
WHERE instr(value, '"definition_id":"bee.') > 0;
