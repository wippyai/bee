Driver option compatibility fixtures

Captured CLI versions: Claude Code 2.1.296 and codex-cli 0.160.1.

coverage.json records each option's ID, type, contexts, native argv or config
mapping, and a fixture value. The help captures record the corresponding CLI
flags, including Codex exec and resume. codex-0.160.1-features.txt records
feature IDs, stages and defaults for that version.

tests/lua/driver/option_coverage_cases.lua mirrors coverage.json for the Lua
runner. option_coverage_test.lua exercises production preparation,
configuration, effective schemas, typed controls, profile storage, the profile
protocol codec and launch-preference reconstruction.

Installed-CLI compatibility proofs live in the private acceptance repository.
A different CLI version requires new captures and updated coverage data.
