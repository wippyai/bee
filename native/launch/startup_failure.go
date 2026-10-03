// SPDX-License-Identifier: MIT
package launch

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"strings"
)

type startupFailure struct {
	cause              error
	detail, log, state string
}

func (failure *startupFailure) Error() string {
	return fmt.Sprintf("Bee could not start: %s\nFull owner log: %s\nTo boot the shipped bundle, run: bee --state %s recover", failure.detail, failure.log, "'"+strings.ReplaceAll(failure.state, "'", "'\\''")+"'")
}
func (failure *startupFailure) Unwrap() error { return failure.cause }

func ownerStartupFailure(cause error, state, log string, abortError error) error {
	detail := cause.Error()
	var logError error
	file, err := os.Open(log)
	if err != nil {
		cause = errors.Join(cause, fmt.Errorf("read owner log: %w", err))
		logError = err
	} else {
		defer file.Close()
		marked := false
		scanner := bufio.NewScanner(file)
		scanner.Buffer(make([]byte, 4096), 1024*1024)
		for scanner.Scan() {
			line := scanner.Text()
			if message, ok := strings.CutPrefix(line, "BEE_STARTUP_FAILED "); ok {
				detail = message
				marked = true
			} else if message, ok := strings.CutPrefix(line, "bee: "); ok && !marked {
				detail = message
			}
		}
		if err := scanner.Err(); err != nil {
			cause = errors.Join(cause, fmt.Errorf("read owner log: %w", err))
			logError = err
		}
	}
	detail, _, _ = strings.Cut(detail, "\n")
	for {
		shortened := detail
		for _, prefix := range []string{
			"Bee owner startup: ",
			"the running Bee owner did not enroll this client: ",
			"Hive supervisor failed before retained workspace readiness: ",
			"Retained desktop owner exited: ",
			"Retained workspace supervisor exited: ",
		} {
			detail = strings.TrimPrefix(detail, prefix)
		}
		if detail == shortened {
			break
		}
	}
	if abortError != nil {
		detail += "; stop failed owner: " + strings.ReplaceAll(abortError.Error(), "\n", "; ")
	}
	if logError != nil {
		detail += "; read owner log: " + logError.Error()
	}
	if logError == nil {
		output, err := os.OpenFile(log, os.O_WRONLY|os.O_APPEND, 0)
		if err == nil {
			_, writeError := fmt.Fprintf(output, "Bee client startup failure:\n%v\n", cause)
			err = errors.Join(writeError, output.Close())
		}
		if err != nil {
			cause = errors.Join(cause, err)
			detail += "; record startup failure in owner log: " + err.Error()
		}
	}
	return &startupFailure{cause: cause, detail: strings.TrimSpace(detail), log: log, state: state}
}
