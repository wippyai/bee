-- MIT. A stored native delivery names Git writable roots by the writable_roots
-- declaration of its CLI descriptor. Each adapter name a saved delivery holds
-- becomes the declaration the built-in descriptor it named carries.
local json = require("json")
local CLAUDE_MODES = {"default", "acceptEdits", "dontAsk"}
local function claude(): {[string]: unknown}
    local when_argv: {{string}} = {}
    for _, mode in ipairs(CLAUDE_MODES) do when_argv[#when_argv + 1] = {"--permission-mode", mode} end
    for _, mode in ipairs(CLAUDE_MODES) do when_argv[#when_argv + 1] = {"--permission-mode=" .. mode} end
    return {when_argv = when_argv, argv_each = {"--add-dir", "{root}"}}
end
local DECLARATIONS: {[string]: {[string]: unknown}} = {
    codex_workspace_write = {when_argv = {{"--sandbox=workspace-write"}, {"--sandbox", "workspace-write"}},
        argv = {"--config", "sandbox_workspace_write.writable_roots={roots}"}},
    claude_add_dir = claude(),
    agy_add_dir = {when_argv = {{"--sandbox"}, {"--sandbox=true"}}, argv_each = {"--add-dir", "{root}"}},
}
return require("migration").define(function()
    migration("Name Git writable roots in stored native deliveries by their descriptor declaration", function()
        database("sqlite", function()
            up(function(db)
                for adapter, declaration in pairs(DECLARATIONS) do
                    local encoded = assert(json.encode(declaration))
                    assert(db:execute([[UPDATE bee_placement_attempts SET request_json = json_set(
                        json_remove(request_json, '$.delivery.git_writable_roots_adapter'), '$.delivery.git_writable_roots', json(?))
                        WHERE json_extract(request_json, '$.delivery.git_writable_roots_adapter') = ?]], {encoded, adapter}))
                end
            end)
        end)
    end)
end)
