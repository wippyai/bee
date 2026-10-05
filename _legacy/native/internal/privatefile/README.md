# Private files

`privatefile` shares the file-locking and atomic-write mechanics used by machine
identity and future machine configuration. Protection relies on the OS account;
other processes under that account can access these files.

`New` validates distinct document and lock basenames without creating files.
`Read` returns bounded bytes, or `os.ErrNotExist` without creating a directory.
`ReadModifyWrite` locks a stable companion inode, validates the existing file,
and runs a transform. A transform error preserves the original; `(nil, nil)`
means no write. Reads and writes share a size bound. The path descriptor retains
no open handles, and there is no exposed raw-write or transaction capability.

Existing insecure permissions, symlinks and nonregular documents are refused
without repair. Updates sync a temporary file before renaming it, then sync the
parent directory. `PublishedSyncError` reports uncertainty if that final sync
fails after publication. Helpers do not include document bytes in their errors;
callers remain responsible for errors returned by their transforms.

Unix uses `flock` and no-follow file opens. Windows uses protected owner ACLs and
rejects reparse points, reserved names and document/lock names that differ only
by case. Windows directory sync remains a no-op; crash durability has not been
verified there.

`make -C native check` runs the native race tests, including concurrent
subprocess updates and identity preservation. Windows uses protected owner
ACLs and rejects reparse points, but `native/Makefile` does not define a
Windows-specific check target, so that path has no repository Make acceptance
command.
