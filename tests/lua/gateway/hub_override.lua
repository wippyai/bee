-- SPDX-License-Identifier: MIT
-- The Hub function a suite substitutes for the effect drains of publication and installation.
local M = {publish = nil :: ((any, boolean) -> any)?, installation = nil :: ((any, boolean) -> any)?}
return M
