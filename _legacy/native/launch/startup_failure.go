// SPDX-License-Identifier: MIT
package launch

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
)

const startupFailurePrefix = "BEE_STARTUP_FAILED "

type startupFailureRecord struct {
	Code      string `json:"code"`
	Component string `json:"component"`
	Subject   string `json:"subject"`
	Message   string `json:"message"`
	Log       string `json:"log"`
}

func (record startupFailureRecord) detail() string {
	return fmt.Sprintf("[%s] %s (%s): %s", record.Code, record.Component, record.Subject, record.Message)
}

func decodeStartupFailure(raw string) (startupFailureRecord, error) {
	var record startupFailureRecord
	decoder := json.NewDecoder(strings.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&record); err != nil {
		return record, err
	}
	if err := decoder.Decode(new(json.RawMessage)); err == nil {
		return record, errors.New("trailing startup failure record")
	} else if err != io.EOF {
		return record, fmt.Errorf("decode trailing startup failure: %w", err)
	}
	for name, value := range map[string]string{"code": record.Code, "component": record.Component, "subject": record.Subject} {
		if value == "" || len(value) > 256 || strings.ContainsAny(value, "\r\n\x00") {
			return record, fmt.Errorf("invalid startup failure %s", name)
		}
	}
	if record.Message == "" || len(record.Message) > 16384 || strings.ContainsRune(record.Message, 0) {
		return record, errors.New("invalid startup failure message")
	}
	if len(record.Log) > 4096 || strings.ContainsAny(record.Log, "\r\n\x00") {
		return record, errors.New("invalid startup failure log path")
	}
	return record, nil
}

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
	var recordError error
	file, err := os.Open(log)
	if err != nil {
		cause = errors.Join(cause, fmt.Errorf("read owner log: %w", err))
		logError = err
	} else {
		defer file.Close()
		scanner := bufio.NewScanner(file)
		scanner.Buffer(make([]byte, 4096), 1024*1024)
		for scanner.Scan() {
			line := scanner.Text()
			if message, ok := strings.CutPrefix(line, startupFailurePrefix); ok {
				record, err := decodeStartupFailure(message)
				if err == nil && record.Log != log {
					err = fmt.Errorf("startup failure log path %q differs from owner log %q", record.Log, log)
				}
				if err != nil {
					recordError = errors.Join(recordError, fmt.Errorf("decode owner startup failure: %w", err))
				} else {
					detail = record.detail()
				}
			}
		}
		if err := scanner.Err(); err != nil {
			cause = errors.Join(cause, fmt.Errorf("read owner log: %w", err))
			logError = err
		}
	}
	if recordError != nil {
		cause = errors.Join(cause, recordError)
		detail += "; " + recordError.Error()
	}
	if abortError != nil {
		detail += "; stop failed owner: " + abortError.Error()
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
	return &startupFailure{cause: cause, detail: detail, log: log, state: state}
}
