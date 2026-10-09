-- SPDX-License-Identifier: MIT
local function pending(): boolean return false end
local function drain(_kind: string): boolean return true end
return {pending = pending, drain = drain}
