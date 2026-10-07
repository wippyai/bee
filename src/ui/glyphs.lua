-- MIT. The one set of small monochrome glyphs Bee's applications draw beside
-- names and state words. Each is a single-cell Unicode symbol in the text
-- role, never an emoji, and carries no color of its own.
local M = {}

-- What a thing is.
M.app = "▣"
M.driver = "⌁"
M.package = "◫"
M.hive = "⬡"
M.capability = "◆"

-- Where a thing stands.
M.installed = "✓"
M.update = "↑"
M.waiting = "◷"
M.installing = "⇣"
M.removed = "✗"
M.replaced = "↻"
M.warning = "⚠"

-- The glyphs in one list, for the checks that every one is a single cell.
M.all = {M.app, M.driver, M.package, M.hive, M.capability, M.installed, M.update, M.waiting,
    M.installing, M.removed, M.replaced, M.warning}

return M
