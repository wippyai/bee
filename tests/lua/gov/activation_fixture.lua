-- SPDX-License-Identifier: MIT
local M = {batches = 0, calls = 0, follows = 0, failure = false, retry = false, uncertain = false, handoff = false, reconciles = 0}
M.ACTIVATION_WORKER_NAME = "bee.test.activation"
M.TOPIC_WAKE = "bee.test.activation.wake"
function M.reset(batches: integer, failure: boolean, retry: boolean)
    M.batches, M.calls, M.follows, M.failure, M.retry = batches, 0, 0, failure, retry
    M.uncertain, M.handoff = false, false
    M.reconciles = 0
end
function M.pending(): boolean return M.batches > 0 end
function M.run(reconcile: boolean?): ({{approval_id: string, kind: string, ok: boolean, phase: string?, outcome: string?, code: string?, message: string?}}?, string?)
    M.calls = M.calls + 1
    if reconcile ~= false then M.reconciles = M.reconciles + 1 end
    if M.uncertain then
        return {{approval_id = "uncertain", kind = "approved", ok = false, phase = "settled",
            outcome = "uncertain", code = "UNCERTAIN", message = "reply lost"}}, nil
    end
    M.batches = math.max(0, M.batches - 1)
    if M.handoff and M.calls == 1 then
        return {{approval_id = "queued", kind = "approved", ok = false, phase = "consuming", outcome = nil,
            code = "CONFLICT", message = "predecessor owns slot"},
            {approval_id = "predecessor", kind = "approved", ok = true, phase = "settled", outcome = "failed",
                code = nil, message = "definite failure"}}, nil
    end
    return {{approval_id = "fixture", kind = "approved", ok = not M.failure, phase = "settled", outcome = "applied", code = "fixture", message = "fixture"}}, nil
end
function M.follow_all(): {ok: boolean, value: {retry: boolean}, message: string?}
    M.follows = M.follows + 1
    return {ok = true, value = {retry = M.retry}, message = nil}
end
return M
