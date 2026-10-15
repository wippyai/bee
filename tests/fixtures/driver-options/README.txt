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

All-allowed profile controls also use captured Agy 1.3.5, Grok 1.0.30,
OpenCode 1.18.32 (root and run), and Muse 1.4.8 (root and exec) help.
Captured on 2026-10-15. Trailing whitespace is trimmed; Muse updater
diagnostics are omitted from its help.
Claude 2.1.300 and Codex 0.162.1 installed help also confirm the bypass flags
in the existing versioned captures. No provider requests or credentials are
needed for these probes.

allowall_test.lua covers production profile storage, person consent, placement
ceilings and argv in window, first_turn and resume contexts. The Python
allowall fixture test checks the flags against these captures. OpenCode --auto
retains explicit denies; Muse --yolo disables both approvals and sandboxing.
Wippy executes in-process and has no CLI descriptor or placement launch.
