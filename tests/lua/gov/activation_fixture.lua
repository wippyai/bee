-- SPDX-License-Identifier: MIT
local M = {batches = 0, calls = 0, follows = 0, failure = false, retry = false}
M.ACTIVATION_WORKER_NAME = "bee.test.activation"
M.TOPIC_WAKE = "bee.test.activation.wake"
function M.reset(batches: integer, failure: boolean, retry: boolean)
    M.batches, M.calls, M.follows, M.failure, M.retry = batches, 0, 0, failure, retry
end
function M.pending(): boolean return M.batches > 0 end
function M.run(): ({{approval_id: string, kind: string, ok: boolean, phase: string?, outcome: string?, code: string?, message: string?}}?, string?)
    M.calls = M.calls + 1
    M.batches = math.max(0, M.batches - 1)
    return {{approval_id = "fixture", kind = "approved", ok = not M.failure, phase = nil, outcome = nil, code = "fixture", message = "fixture"}}, nil
end
function M.follow_all(): {ok: boolean, value: {retry: boolean}, message: string?}
    M.follows = M.follows + 1
    return {ok = true, value = {retry = M.retry}, message = nil}
end
return M
