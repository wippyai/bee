local sql = require("sql")
local json = require("json")
local process = require("process")
local protocol = require("protocol")
local bounds = require("bounds")
local homes = require("homes")
local trust = require("trust")
local clock = require("clock")
local M = {}
type Object = {[string]: unknown}
function M.bind(db: sql.DB, attempt: string, grant: string, home: string, mapping: Object): string?
    local tx, begin_error = db:begin()
    if not tx then return tostring(begin_error) end
    local rows, read_error = tx:query([[SELECT a.runner_pid,r.control_token FROM bee_placement_attempts a
        JOIN bee_placement_runner_authorities r ON r.attempt_id=a.attempt_id WHERE a.attempt_id=? AND a.execution_state='starting']], {attempt})
    if not rows or read_error or #rows ~= 1 then tx:rollback(); return "Folder trust requires an active runner authority" end
    local runner, token = bounds.id(rows[1].runner_pid), bounds.id(rows[1].control_token)
    if not runner or not token then tx:rollback(); return "Folder trust runner authority is invalid" end
    local mapping_json = assert(json.encode(mapping))
    local _, err = tx:execute("INSERT INTO bee_placement_trust(attempt_id,grant_id,home_path,mapping_json) VALUES (?,?,?,?)", {attempt, grant, home, mapping_json})
    if err then tx:rollback(); return tostring(err) end
    local context = {home_path = home, mapping_json = mapping_json, runner_pid = runner, control_token = token}
    local _, effect_error = tx:execute("INSERT INTO bee_approval_grant_effects(grant_id,destination,effect_id,context_json) VALUES (?,'placement.folder_trust',?,?)",
        {grant, attempt, json.encode(context)})
    if effect_error then tx:rollback(); return tostring(effect_error) end
    local committed, commit_error = tx:commit()
    if not committed or commit_error then tx:rollback(); return tostring(commit_error) end
    return nil
end

function M.publish(db: sql.DB, attempt: string, content: string, created: {[string]: boolean}): (string?, string?, boolean?)
    local tx, begin_error = db:begin()
    if not tx then return nil, tostring(begin_error), false end
    local _, lock_error = tx:execute("UPDATE bee_placement_trust SET grant_id = grant_id WHERE attempt_id = ?", {attempt})
    if lock_error then tx:rollback(); return nil, tostring(lock_error), false end
    local rows, read_error = tx:query([[SELECT t.home_path,t.mapping_json FROM bee_placement_trust t
        JOIN bee_approval_grants g ON g.grant_id=t.grant_id JOIN bee_placement_attempts a ON a.attempt_id=t.attempt_id
        WHERE t.attempt_id=? AND g.state='active' AND json_extract(g.provenance_json,'$.kind')='consent'
        AND (g.until_ms IS NULL OR g.until_ms>?) AND a.execution_state='starting']], {attempt, clock.milliseconds()})
    if not rows or read_error or #rows ~= 1 then tx:rollback(); return nil, "Folder trust attempt or person consent is no longer active", false end
    local mapping = bounds.object(json.decode(tostring(rows[1].mapping_json)))
    local file = mapping and bounds.subpath(mapping.file)
    local home = bounds.text(rows[1].home_path, 512)
    if not file or not home then tx:rollback(); return nil, "Invalid folder trust publication", false end
    local written, write_error, uncertain = homes.publish_configuration(home, file, content, created, true)
    if not written then tx:rollback(); return nil, write_error, uncertain end
    local committed, commit_error = tx:commit()
    if not committed or commit_error then tx:rollback(); return nil, "Commit folder trust publication: " .. tostring(commit_error), true end
    return written, nil, false
end
local function clear_rows(rows: {Object}): string?
    for _, row in ipairs(rows) do
        local mapping = bounds.object(json.decode(tostring(row.mapping_json)))
        local home = bounds.text(row.home_path, 512)
        if not mapping or not home then return "Invalid recorded folder trust destination" end
        if mapping.file then
            local file = bounds.subpath(mapping.file)
            if not file then return "Invalid recorded folder trust file" end
            local source, read_error = homes.read_isolated_configuration(home, file)
            if read_error then return read_error end
            if source then
                local content, render_error = trust.render(mapping, nil, source)
                if not content then return render_error end
                local written, write_error = homes.publish_configuration(home, file, content, {}, true)
                if not written then return write_error end
            end
        elseif not bounds.line(mapping.flag, 128) then return "Invalid recorded folder trust mapping" end
    end
    return nil
end
function M.finish(db: sql.Transaction | sql.DB, attempt: string): string?
    local rows, err = db:query("SELECT home_path,mapping_json FROM bee_placement_trust WHERE attempt_id = ?", {attempt})
    if not rows or err then return "Read folder trust lifetime: " .. tostring(err) end
    local invalid = clear_rows(rows)
    if invalid then return invalid end
    local _, effect_error = db:execute("DELETE FROM bee_approval_grant_effects WHERE destination='placement.folder_trust' AND effect_id=?", {attempt})
    if effect_error then return tostring(effect_error) end
    local _, removed = db:execute("DELETE FROM bee_placement_trust WHERE attempt_id = ?", {attempt})
    return removed and tostring(removed) or nil
end
function M.revoke(raw: unknown): string?
    local value = bounds.object(raw)
    local context = value and bounds.object(value.context)
    if not value or not bounds.id(value.grant_id) or not bounds.id(value.effect_id) or not context then return "Invalid folder trust revocation effect" end
    local invalid = clear_rows({context})
    if invalid then return invalid end
    local runner, token = bounds.id(context.runner_pid), bounds.id(context.control_token)
    if not runner or not token then return "Trusted attempt has no runner authority for revocation" end
    local sent, send_error = process.send(runner, protocol.TOPIC_CONTROL, {command = "stop", control_token = token, mode = "forced", grace_ms = 0})
    if not sent then return "Stop revoked trust: " .. tostring(send_error) end
    return nil
end
return M
