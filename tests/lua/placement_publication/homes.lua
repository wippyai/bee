-- SPDX-License-Identifier: MIT
-- Inject only filesystem outcomes. Admission state/evidence uses the real store.
local real = require("real")
local M = {publications = 0, creations = 0}
M.decode_login_source = real.decode_login_source
M.retain_login = real.retain_login
M.write_protected = real.write_protected
M.attempt_key = real.attempt_key
M.session_key = real.session_key
function M.reset()
    M.publications = 0
    M.creations = 0
end
function M.create_attempt(key: string): (string?, string?)
    M.creations = M.creations + 1
    return "/fixture/attempt/" .. key, nil
end
function M.ensure_session(key: string): (string?, string?)
    return "/fixture/session/" .. key, nil
end
function M.os_path(path: string): (string?, string?) return path, nil end
function M.check_private_root(): string? return nil end
function M.publish_configuration(home: string, path: string, content: string, created: {[string]: boolean}?): (string?, string?, boolean?)
    M.publications = M.publications + 1
    return nil, "configuration published; durability requires inspection", true
end
return M
