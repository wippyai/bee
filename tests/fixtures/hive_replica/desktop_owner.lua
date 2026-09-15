-- MIT. No desktop is enabled in the replica transport fixture.
local M = {}
type State = {}
function M.handles(_state: State, _message: unknown): boolean return false end
function M.request(_state: State, _message: unknown, _elapsed: integer) end
function M.start(_config: unknown, _node: string): State return {} end
function M.event(_state: State, _message: unknown, _now: integer) end
function M.tick(_state: State, _now: integer) end
function M.catalog_result(_state: State, _message: unknown, _now: integer) end
function M.activated(_state: State, _message: unknown, _now: integer) end
function M.ready(_state: State, _message: unknown) end
function M.result(_state: State, _message: unknown, _now: integer) end
function M.launched(_state: State, _message: unknown, _now: integer) end
function M.copied(_state: State, _message: unknown, _now: integer) end
function M.close(_state: State) end
return M
