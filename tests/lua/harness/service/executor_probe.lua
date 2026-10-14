local M = {}
function M.main(value: unknown, constructors: unknown, retained: boolean, operation_key: string, admitted: {[string]: unknown}?): unknown
    return admitted and admitted.request_id
end
function M.constructors(): {[string]: unknown} return {} end
return M
