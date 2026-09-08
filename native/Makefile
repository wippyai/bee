export GOWORK := off
export GOTOOLCHAIN := go1.27.0
TAGS := fts5 sqlite_vec treesitter sqlite_preupdate_hook
.PHONY: check test
check: test
	go vet -tags "$(TAGS)" ./...
test:
	go test -race -tags "$(TAGS)" ./...
