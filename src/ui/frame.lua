-- MIT. The shared application frame, the toolkit every Bee application draws
-- with: one header, tabs, one action and key-hint footer, scrolling rows,
-- tables, trees, inspectors and logs, layout regions, documents, cards and an
-- empty or error state, all drawn from semantic appearance roles, plus the
-- More, Help and row-action overlay an app routes its input through. This is
-- the toolkit's public surface; bee.ui.frame:paint draws the frame,
-- bee.ui.frame:lists the data views and bee.ui.frame:overlay the overlay.
local paint = require("paint")
local lists = require("lists")
local overlay = require("overlay")
local M = {}
type Hit = paint.Hit
type Button = paint.Button
type Tab = paint.Tab
type Hint = paint.Hint
type RowActions = paint.RowActions
type Controls = paint.Controls
type Bar = paint.Bar
type Painter = paint.Painter
type View = paint.View
type Window = paint.Window
type ListCard = paint.ListCard
type Rect = paint.Rect
type Layout = paint.Layout
type Toast = paint.Toast
type Line = paint.Line
type Column = lists.Column
type Table = lists.Table
type TreeRow = lists.TreeRow
type TreeView = lists.TreeView
type Entry = lists.Entry
type Inspector = lists.Inspector
type LogLine = lists.LogLine
type LogView = lists.LogView
type MenuItem = overlay.MenuItem
type PopupState = overlay.PopupState
type Panel = overlay.Panel
type Context = overlay.Context
type Menu = overlay.Menu
type Clicks = overlay.Clicks

M.fit = paint.fit
M.pad = paint.pad
M.tagged = paint.tagged
M.new = paint.new
M.rows = paint.rows
M.put = paint.put
M.clip = paint.clip
M.fill = paint.fill
M.line = paint.line
M.rule = paint.rule
M.add_hit = paint.add_hit
M.hit = paint.hit
M.header = paint.header
M.tabs = paint.tabs
M.button = paint.button
M.controls = paint.controls
M.actions = paint.actions
M.hints = paint.hints
M.footer = paint.footer
M.window = paint.window
M.row = paint.row
M.list_card = paint.list_card
M.size = paint.size
M.layout = paint.layout
M.split = paint.split
M.stack = paint.stack
M.grid = paint.grid
M.section = paint.section
M.panel = paint.panel
M.flow = paint.flow
M.document = paint.document
M.card = paint.card
M.cards = paint.cards
M.master_detail = paint.master_detail
M.field = paint.field
M.steps = paint.steps
M.empty = paint.empty
M.badge = paint.badge
M.toast = paint.toast
M.modal = paint.modal
M.row_actions = paint.row_actions
M.table = lists.table
M.tree = lists.tree
M.kv = lists.kv
M.log = lists.log
M.menu = overlay.menu
M.render = overlay.render
M.route = overlay.route
M.clicks = overlay.clicks
M.double_click = overlay.double_click
M.DOUBLE_CLICK_MS = overlay.DOUBLE_CLICK_MS

return M
