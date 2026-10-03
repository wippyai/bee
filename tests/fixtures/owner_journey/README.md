# Owner journey acceptance

Run an existing standalone binary against an existing state directory:

```sh
make owner-journey BEE_BINARY=/path/to/bee BEE_SOURCE_STATE=/path/to/state
```

An empty source directory exercises fresh state. The target never builds a Bee
binary, pushes changes, changes the source state, or applies a public Hub update.
It uses `NativeDesktop` and the existing synchronized-frame PTY decoder.

State is copied under `.wippy/owner-journey-work/`: SQLite read-only backups
include committed WAL data; other regular files use `cp -a`. Names matching
`cred|secret|token|key`, provider `auth.json`, PEM files and links are excluded
before opening them. SQLite sidecars are excluded. Copied runtime caches are
archived outside the selected state so Bee can rematerialize excluded module
artifacts from its binary, while all copied owner databases remain intact.
Bee creates its fresh credential store. The work directory is removed after
process cleanup; provider homes and credential projections are never evidence.

The journey reports every requested step, including dependent failures after a
startup refusal. Step 7 runs last, after the extended cases. Step 4 accepts only
running or an explicit `start_failed` carrying the Docker daemon's cause; the
real subscription case still fails if Docker cannot run. Claude is required;
Codex is exercised when its OS-user subscription login evidence exists. The
native fixture emits protocol initialization and waits on a named pipe until
the test observes both a rendered working state and placement's running state.
Real agents use Bee's credential projection and the OS user's subscription;
API-key environment variables are removed, and provider login-status metadata
must confirm subscription authentication before inference. The test never reads
login files.

Update Bee is reached through Settings/About and Modules/Installed, its current
UI location. The test starts the repository's loopback Hub fixture from the
binary's sibling `portable-deployment/hub` sealed artifacts. Its private
candidate changes About's code marker. No public release is installed. The
Hive case uses two isolated state directories and a single-use invite on the
same machine; it asserts remote live app counts and an Inbox decision.

Governance steps request the actual host edit-mode grant, have an agent author
through its admitted tools, and assert the reviewed candidate, approval, live
change, recovery and removal. A missing grant, protected-kernel refusal, absent
publication path, failed provider or failed Hive operation is a failing case,
not a skip. Bee capability fixes belong in separate lanes.

Waits observe complete rendered frames and owner revisions/phases. The default
600-second bound diagnoses **no progress**, not startup or provider speed.
CLI waits have an explicit acknowledgement hang bound; fixture teardown has a
10-second stop grace before escalation. Timing is evidence, never a pass rule.
Set `BEE_JOURNEY_HANG_SECONDS` to configure the diagnostic bound for a run.

`.wippy/owner-journey/report.txt` is printed and contains PASS/FAIL, elapsed
seconds, frame paths, approval counts and exact causes. Each run retains frame
files, safe owner-state snapshots, copied/excluded path inventory and subcase
outcomes. Approval requests are recorded by owner identity, proposal scope,
prompt, duration and previous grant; repeated grants, split decisions, routine
opening prompts and incomplete/overlong prompt screens fail the journey.

Harness safety regressions run with:

```sh
python3 -m unittest discover -s tests -p test_owner_journey.py
```
