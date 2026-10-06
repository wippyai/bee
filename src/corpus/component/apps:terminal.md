# bee.apps.terminal

A native local shell as a desktop application. `bee.apps.terminal:app`
(`meta.type: bee.app`, singleton, `terminal: true`, in `bee.shell:apps_menu`) runs the
person's shell in the desktop's workspace folder and renders its PTY in the
app's terminal port; the app returns only after the child is reaped.

Launch arguments are the command to run as words; `bee.apps.terminal:command`
quotes them without shell expansion, and no arguments start `/bin/bash -i`.
The app acquires its own executor, `bee.apps.terminal:executor` (`exec.native`,
`TERM=xterm-256color`, `PATH`, `HOME`, `USER` and `LANG` from the process
environment), through the policies `acquire` and `run`; `run` allows
`exec.run` only for that executor.
