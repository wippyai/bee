-- SPDX-License-Identifier: MIT
-- The point libraries the suites' seam binding dispatches to.
local placement_native = require("placement_native")
local placement_docker = require("placement_docker")
local harness = require("harness")
local process = require("process")
local hive = require("hive")
local approvals = require("approvals")
local inbox = require("inbox")
local node = require("node")
local shell = require("shell")
local gov = require("gov")
local sync = require("sync")
local gateway = require("gateway")
local credentials = require("credentials")
local resources = require("resources")
local hub = require("hub")
local threads = require("threads")
return {placement_native, placement_docker, harness, process, hive, approvals, inbox, node, shell, gov, sync, gateway, credentials, resources, hub, threads}
