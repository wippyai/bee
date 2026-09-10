export GOWORK := off
export GOTOOLCHAIN := go1.27.0
.PHONY: check windows-check
check:
	go test -race -count=1 ./...
	go vet ./...
windows-check:
	@test -n "TEST_EXE" || { echo 'Set TEST_EXE to a temporary Windows test executable path' >&2; exit 1; }
	GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go test -c -o "$(TEST_EXE)" .
	GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go vet ./...
