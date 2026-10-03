-- SPDX-License-Identifier: MIT
local ledger = require("ledger")
local SCHEMA = [[
CREATE TABLE client_state (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    client_id TEXT NOT NULL CHECK (length(client_id) = 32 AND client_id NOT GLOB '*[^0-9a-f]*'),
    generation INTEGER NOT NULL CHECK (generation >= 0),
    value TEXT CHECK (value IS NULL OR length(CAST(value AS BLOB)) <= 2097152),
    import_workspace TEXT NOT NULL DEFAULT '',
    import_receipt TEXT NOT NULL DEFAULT ''
);
INSERT INTO client_state (singleton, client_id, generation)
VALUES (1, lower(hex(randomblob(16))), 0)
]]
local DESKTOPS = [[
CREATE TABLE client_desktops (
    client_id TEXT NOT NULL PRIMARY KEY CHECK (length(client_id) = 32 AND client_id NOT GLOB '*[^0-9a-f]*'),
    generation INTEGER NOT NULL DEFAULT 0 CHECK (generation >= 0),
    value TEXT CHECK (value IS NULL OR length(CAST(value AS BLOB)) <= 2097152),
    import_workspace TEXT NOT NULL DEFAULT '',
    import_receipt TEXT NOT NULL DEFAULT ''
)
]]
local LAYOUTS = [[
CREATE TABLE client_layouts (
    desktop_id TEXT NOT NULL CHECK (length(desktop_id) = 32 AND desktop_id NOT GLOB '*[^0-9a-f]*'),
    workspace_id TEXT NOT NULL CHECK (length(workspace_id) = 32 AND workspace_id NOT GLOB '*[^0-9a-f]*'),
    generation INTEGER NOT NULL CHECK (generation >= 1 AND generation <= 9007199254740990),
    value TEXT NOT NULL CHECK (length(CAST(value AS BLOB)) <= 2097152),
    import_receipt TEXT NOT NULL CHECK (import_receipt = '' OR (length(import_receipt) = 32 AND import_receipt NOT GLOB '*[^0-9a-f]*')),
    PRIMARY KEY (desktop_id, workspace_id)
)
]]
local migrations: {ledger.Migration} = {
    {id = 1, name = "client_layout_v1", sql = SCHEMA},
    {id = 2, name = "independent_desktops_v1", sql = DESKTOPS},
    {id = 3, name = "workspace_layouts_v1", sql = LAYOUTS},
}
return migrations
