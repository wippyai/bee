CREATE TABLE workspace_folder (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    created INTEGER NOT NULL CHECK (created IN (0, 1))
);
INSERT INTO workspace_folder (singleton, created)
SELECT 1, 1 - (SELECT fresh FROM temp.workspace_migration_run);
DELETE FROM workspaces
WHERE root_ref = 'bee:workspace_root' AND subpath = ''
    AND (SELECT fresh FROM temp.workspace_migration_run) = 1
