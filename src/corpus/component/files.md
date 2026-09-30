# Files

`bee.files.app:app` browses a workspace tree and previews text with line numbers
and tree-sitter highlighting. Its UI lives in `bee.files.app`; the root owns
path decoding, ignore matching, the lazy tree and syntax documents.

The host links `target_workspace_root` to a filesystem resource through
`bee.files:workspace_root_ref`, and selects the app's admission policy.
Bee's stock admission grants only that reference and `bee.env:files_root`,
a read-only volume rooted in the launch project. Importing `fs` grants no
volume access. Stock admission does not need the delivered-package module
ceiling to permit `fs` or `treesitter`. The host selects `observe_post` for
Files because the approved agent runtime opener requires a broker-bound
initiating thread; this gives its exact instance the public thread facade,
not direct access to thread storage.

Enter expands a directory or opens a file, Tab switches panes, `/` searches
files in loaded directories, and G jumps to a line. The shared frame's
F10 More and `?` Help remain available on compact frames. Private `.wippy` and `.git` trees, traversal and
absolute paths are rejected. Directory loads and search results are bounded.

An agent with approved `bee.application:runtime` access opens Files through
`application_open`, with `definition_id: bee.files.app:app` and literal
`arguments: ["src/clock.lua:2-4"]`. The preview marks the requested range.
Files uses singleton admission; opening an existing instance with new arguments
moves its retained preview to the requested file and range. The shared reopen
navigation uses the `bee.application.navigate` topic. Files calls
`client.navigation` to authenticate the broker, instance, view, execution
generation and launch token before decoding its bounded arguments. Other
senders, stale payloads and unsafe paths are ignored. This message is not an
agent tool.
