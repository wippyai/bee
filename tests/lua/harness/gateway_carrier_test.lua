-- MIT. Focused gateway carrier test cases.
local support = require("support")
local run_cases = support.run_cases
local define_tests = require("gateway_carrier_flow_cases").define
local define_extension_tests = require("gateway_carrier_extension_cases").define
local define_fencing_tests = require("gateway_carrier_fencing_cases").define
return {run = run_cases(define_tests), fencing = run_cases(define_fencing_tests), extensions = run_cases(define_extension_tests)}
