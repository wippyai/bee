-- MIT. Results the authority returns and the shapes its values take.
type Fault = {code: string, message: string, retryable: boolean}
type Reply = {ok: boolean, error: Fault?, value: unknown, replayed: boolean}
type Summary = {thread_id: string, title: string, state: string, revision: integer, head_sequence: integer, owner_id: string, created_at: string,
    workspace_id: string?}
type Membership = {member_id: string, role: string, revision: integer, active: boolean}
type Committed = {record_id: string, sequence: integer}
local M = {}
return M
