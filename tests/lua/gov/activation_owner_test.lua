-- MIT. Focused activation owner test cases.
local test = require("test")
local support = require("support")
local admission = support.admission
local authority_tests = require("activation_authority_cases").define
local admission_tests = require("activation_admission_cases").define
local recovery_tests = require("activation_recovery_cases").define
local migration_tests = require("activation_migration_cases").define
local follow_tests = require("activation_follow_cases").define
return {run = test.run_cases(authority_tests), admission = test.run_cases(admission_tests),
    recovery = test.run_cases(recovery_tests), migration = test.run_cases(migration_tests), follow = test.run_cases(follow_tests)}
