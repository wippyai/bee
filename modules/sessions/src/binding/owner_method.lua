-- MIT. Contract methods enter through the Sessions owner.
local owner = require("owner")
local M = {}
function M.open(request: unknown): unknown return owner.call("open", request) end
function M.run(request: unknown): unknown return owner.call("run", request) end
function M.send(request: unknown): unknown return owner.call("send", request) end
function M.await(request: unknown): unknown return owner.call("await", request) end
function M.join(request: unknown): unknown return owner.call("join", request) end
function M.get(request: unknown): unknown return owner.call("get", request) end
function M.list(request: unknown): unknown return owner.call("list", request) end
function M.cancel(request: unknown): unknown return owner.call("cancel", request) end
function M.close(request: unknown): unknown return owner.call("close", request) end
function M.catalog(request: unknown): unknown return owner.call("catalog", request) end
return M
