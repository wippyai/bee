// SPDX-License-Identifier: MIT

// Package hookpost contains the small native boundary used by harness hook
// processes. It only submits an observation to the already-running gateway;
// it does not start Bee, open a store, or interpret a hook response.
package hookpost

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	MaxPayloadBytes   = 32768
	MaxActionBytes    = 128
	MaxEndpointBytes  = 128
	MaxEnvNameBytes   = 128
	MaxTokenPathBytes = 4096
	MaxTokenFileBytes = 8192
	MaxTokenBytes     = 4096
	RequestTimeout    = 2 * time.Second
)

var knownEvents = map[string]struct{}{
	"SessionStart":       {},
	"UserPromptSubmit":   {},
	"PreToolUse":         {},
	"PostToolUse":        {},
	"PostToolUseFailure": {},
	"Stop":               {},
	"StopFailure":        {},
	"SessionEnd":         {},
}

// Run validates the command values, reads one bounded JSON object from stdin,
// and submits it once. stdin must be closeable so cancellation can interrupt a
// blocked read (os.Stdin satisfies this contract).
func Run(ctx context.Context, stdin io.ReadCloser, endpoint, actionID, tokenSource, event string) error {
	if ctx == nil {
		return errors.New("hook-post: context is required")
	}
	if stdin == nil {
		return errors.New("hook-post: stdin is required")
	}
	if err := validateEndpoint(endpoint); err != nil {
		return err
	}
	if !safeSegment(actionID, MaxActionBytes) {
		return errors.New("hook-post: invalid action id")
	}
	if _, ok := knownEvents[event]; !ok {
		return errors.New("hook-post: invalid event")
	}
	token, tokenError := resolveToken(tokenSource)
	if tokenError != nil {
		return tokenError
	}

	requestCtx, cancel := context.WithTimeout(ctx, RequestTimeout)
	defer cancel()
	if err := requestCtx.Err(); err != nil {
		return err
	}
	raw, err := readBounded(requestCtx, stdin)
	if err != nil {
		return err
	}
	body, err := payload(raw, event)
	if err != nil {
		return err
	}
	if err := requestCtx.Err(); err != nil {
		return err
	}

	url := "http://" + endpoint + "/hook/" + actionID
	request, err := http.NewRequestWithContext(requestCtx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return errors.New("hook-post: request could not be created")
	}
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Content-Type", "application/json")
	client := &http.Client{
		Transport: &http.Transport{
			Proxy:             nil,
			DisableKeepAlives: true,
			DialContext: (&net.Dialer{
				Timeout: 1 * time.Second,
			}).DialContext,
		},
		// Keep a redirect response at the original endpoint. Hook delivery is
		// one request and must never be redirected to another authority.
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	response, err := client.Do(request)
	if err != nil {
		if contextErr := requestCtx.Err(); contextErr != nil {
			return contextErr
		}
		return errors.New("hook-post: request failed")
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK && response.StatusCode != http.StatusAccepted {
		return errors.New("hook-post: gateway rejected request with status " + strconv.Itoa(response.StatusCode))
	}
	return nil
}

func resolveToken(source string) (string, error) {
	if strings.HasPrefix(source, "@") {
		path := source[1:]
		if len(path) == 0 || len(path) > MaxTokenPathBytes || !filepath.IsAbs(path) || strings.ContainsRune(path, '\x00') {
			return "", errors.New("hook-post: invalid token source")
		}
		token, err := readTokenFile(path)
		if err != nil {
			// The path, filesystem error and document contents are deliberately
			// omitted: this source contains a credential and is host-selected.
			return "", errors.New("hook-post: hook token is unavailable")
		}
		return token, nil
	}
	if !safeEnvName(source) {
		return "", errors.New("hook-post: invalid token source")
	}
	token, ok := os.LookupEnv(source)
	if !ok || !validToken(token) {
		return "", errors.New("hook-post: hook token is unavailable")
	}
	return token, nil
}

func readTokenFile(path string) (string, error) {
	info, err := os.Lstat(path)
	if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return "", errors.New("token file is not regular")
	}
	file, err := os.Open(path)
	if err != nil {
		return "", errors.New("token file could not be opened")
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil || !opened.Mode().IsRegular() || !os.SameFile(info, opened) {
		return "", errors.New("token file is not regular")
	}
	data, err := io.ReadAll(io.LimitReader(file, MaxTokenFileBytes+1))
	if err != nil || len(data) > MaxTokenFileBytes {
		return "", errors.New("token file exceeds its bound")
	}
	return decodeTokenFile(data)
}

func decodeTokenFile(data []byte) (string, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	opening, err := decoder.Token()
	if err != nil {
		return "", errors.New("token file is malformed")
	}
	delim, ok := opening.(json.Delim)
	if !ok || delim != '{' {
		return "", errors.New("token file must contain one object")
	}
	var token string
	seen := false
	for decoder.More() {
		name, nameError := decoder.Token()
		if nameError != nil {
			return "", errors.New("token file is malformed")
		}
		field, fieldOK := name.(string)
		if !fieldOK || field != "token" || seen {
			return "", errors.New("token file contains an unknown or duplicate field")
		}
		var raw json.RawMessage
		if decodeError := decoder.Decode(&raw); decodeError != nil {
			return "", errors.New("token file is malformed")
		}
		var candidate string
		if json.Unmarshal(raw, &candidate) != nil || !validToken(candidate) {
			return "", errors.New("token file token is invalid")
		}
		token = candidate
		seen = true
	}
	closing, closeError := decoder.Token()
	if closeError != nil {
		return "", errors.New("token file is malformed")
	}
	closingDelim, closingOK := closing.(json.Delim)
	if !closingOK || closingDelim != '}' || !seen {
		return "", errors.New("token file must contain exactly one token")
	}
	var extra json.RawMessage
	if extraError := decoder.Decode(&extra); extraError != io.EOF {
		return "", errors.New("token file contains multiple JSON documents")
	}
	return token, nil
}

func validateEndpoint(endpoint string) error {
	if len(endpoint) == 0 || len(endpoint) > MaxEndpointBytes {
		return errors.New("hook-post: invalid endpoint")
	}
	host, port, ok := strings.Cut(endpoint, ":")
	if !ok || host != "127.0.0.1" || port == "" || strings.Contains(port, ":") {
		return errors.New("hook-post: invalid endpoint")
	}
	for _, char := range port {
		if char < '0' || char > '9' {
			return errors.New("hook-post: invalid endpoint")
		}
	}
	value, err := strconv.Atoi(port)
	if err != nil || value < 1 || value > 65535 {
		return errors.New("hook-post: invalid endpoint")
	}
	return nil
}

func safeSegment(value string, limit int) bool {
	if len(value) == 0 || len(value) > limit {
		return false
	}
	for index, char := range value {
		if (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') ||
			(char >= '0' && char <= '9') || char == '-' || char == '_' || char == '.' || char == ':' {
			if index == 0 && char == '.' {
				return false
			}
			continue
		}
		return false
	}
	return true
}

func safeEnvName(value string) bool {
	if len(value) == 0 || len(value) > MaxEnvNameBytes {
		return false
	}
	for index, char := range value {
		if (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') || char == '_' || (index > 0 && char >= '0' && char <= '9') {
			continue
		}
		return false
	}
	return true
}

func validToken(token string) bool {
	if len(token) == 0 || len(token) > MaxTokenBytes {
		return false
	}
	for _, char := range token {
		if char <= ' ' || char == 0x7f || char == '\r' || char == '\n' {
			return false
		}
	}
	return true
}

func readBounded(ctx context.Context, stdin io.ReadCloser) ([]byte, error) {
	type result struct {
		data []byte
		err  error
	}
	results := make(chan result, 1)
	go func() {
		data, err := io.ReadAll(io.LimitReader(stdin, MaxPayloadBytes+1))
		results <- result{data: data, err: err}
	}()
	select {
	case result := <-results:
		if len(result.data) > MaxPayloadBytes {
			return nil, errors.New("hook-post: input exceeds 32768 bytes")
		}
		if result.err != nil {
			return nil, errors.New("hook-post: input could not be read")
		}
		return result.data, nil
	case <-ctx.Done():
		// Closing the owner is what interrupts a pipe/file read. The read
		// goroutine owns no state and its buffered result cannot block return.
		_ = stdin.Close()
		return nil, ctx.Err()
	}
}

func payload(raw []byte, event string) ([]byte, error) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	fields := map[string]json.RawMessage{}
	if err := decoder.Decode(&fields); err != nil || fields == nil {
		return nil, errors.New("hook-post: input is not a JSON object")
	}
	var extra json.RawMessage
	if err := decoder.Decode(&extra); err != io.EOF {
		return nil, errors.New("hook-post: input contains multiple JSON documents")
	}
	for _, name := range []string{"hook_event_name", "event"} {
		value, exists := fields[name]
		if !exists {
			continue
		}
		var claimed string
		if err := json.Unmarshal(value, &claimed); err != nil || claimed != event {
			return nil, errors.New("hook-post: input event conflicts with command event")
		}
	}
	encodedEvent, err := json.Marshal(event)
	if err != nil {
		return nil, errors.New("hook-post: input could not be prepared")
	}
	fields["hook_event_name"] = encodedEvent
	body, err := json.Marshal(fields)
	if err != nil || len(body) > MaxPayloadBytes {
		return nil, errors.New("hook-post: input exceeds 32768 bytes")
	}
	return body, nil
}
