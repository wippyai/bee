// SPDX-License-Identifier: MIT

package config

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"strconv"
	"strings"
	"unicode/utf8"
)

// Decode parses and strictly validates a JSON-encoded machine configuration document.
// It enforces all schema constraints, disallows unknown fields, duplicate keys,
// null fields, and trailing content. Revision must be positive (>= 1).
func Decode(data []byte) (Document, error) {
	return decodeDocument(data, true)
}

func decodeDocument(data []byte, fromDisk bool) (Document, error) {
	if !utf8.Valid(data) {
		return Document{}, fmt.Errorf("%w: invalid UTF-8", ErrMalformedDocument)
	}
	if int64(len(data)) > MaxDocumentBytes {
		return Document{}, fmt.Errorf("%w: document size exceeds limit", ErrMalformedDocument)
	}
	if len(bytes.TrimSpace(data)) == 0 {
		return Document{}, fmt.Errorf("%w: empty document", ErrMalformedDocument)
	}

	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()

	tok, err := dec.Token()
	if err != nil {
		return Document{}, fmt.Errorf("%w: invalid JSON syntax", ErrMalformedDocument)
	}
	delim, ok := tok.(json.Delim)
	if !ok || delim != '{' {
		return Document{}, fmt.Errorf("%w: expected JSON object", ErrMalformedDocument)
	}

	seen := make(map[string]bool, 4)
	var doc Document

	for dec.More() {
		tok, err := dec.Token()
		if err != nil {
			return Document{}, fmt.Errorf("%w: invalid JSON syntax", ErrMalformedDocument)
		}
		key, ok := tok.(string)
		if !ok {
			return Document{}, fmt.Errorf("%w: expected string key", ErrMalformedDocument)
		}
		if seen[key] {
			return Document{}, fmt.Errorf("%w: duplicate field", ErrMalformedDocument)
		}
		seen[key] = true

		switch key {
		case "version":
			doc.Version, err = decodeVersion(dec)
		case "revision":
			doc.Revision, err = decodeRevision(dec, fromDisk)
		case "hive":
			doc.Hive, err = decodeHiveProfile(dec)
		case "workspaces":
			doc.Workspaces, err = decodeWorkspaces(dec)
		default:
			return Document{}, fmt.Errorf("%w: unknown field", ErrMalformedDocument)
		}
		if err != nil {
			return Document{}, err
		}
	}

	tok, err = dec.Token()
	if err != nil || tok != json.Delim('}') {
		return Document{}, fmt.Errorf("%w: expected end of JSON object", ErrMalformedDocument)
	}

	if !seen["version"] || !seen["revision"] || !seen["hive"] || !seen["workspaces"] {
		return Document{}, fmt.Errorf("%w: missing required field", ErrMalformedDocument)
	}

	tok, err = dec.Token()
	if err != io.EOF {
		return Document{}, fmt.Errorf("%w: trailing content", ErrMalformedDocument)
	}

	if err := validateDocument(doc, fromDisk); err != nil {
		return Document{}, err
	}

	return doc, nil
}

func decodeVersion(dec *json.Decoder) (int, error) {
	tok, err := dec.Token()
	if err != nil {
		return 0, fmt.Errorf("%w: invalid JSON syntax", ErrMalformedDocument)
	}
	if tok == nil {
		return 0, fmt.Errorf("%w: null field", ErrMalformedDocument)
	}
	num, ok := tok.(json.Number)
	if !ok {
		return 0, fmt.Errorf("%w: invalid field type for version", ErrMalformedDocument)
	}
	s := string(num)
	if strings.ContainsAny(s, ".eE-+") {
		return 0, fmt.Errorf("%w: invalid field type for version", ErrMalformedDocument)
	}
	v, err := strconv.ParseInt(s, 10, 32)
	if err != nil || v != CurrentVersion {
		return 0, fmt.Errorf("%w: unsupported version", ErrMalformedDocument)
	}
	return int(v), nil
}

func decodeRevision(dec *json.Decoder, fromDisk bool) (uint64, error) {
	tok, err := dec.Token()
	if err != nil {
		return 0, fmt.Errorf("%w: invalid JSON syntax", ErrMalformedDocument)
	}
	if tok == nil {
		return 0, fmt.Errorf("%w: null field", ErrMalformedDocument)
	}
	num, ok := tok.(json.Number)
	if !ok {
		return 0, fmt.Errorf("%w: invalid field type for revision", ErrMalformedDocument)
	}
	s := string(num)
	if strings.ContainsAny(s, ".eE-+") {
		return 0, fmt.Errorf("%w: invalid field type for revision", ErrMalformedDocument)
	}
	rev, err := strconv.ParseUint(s, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("%w: invalid revision", ErrMalformedDocument)
	}
	if fromDisk && rev == 0 {
		return 0, fmt.Errorf("%w: revision must be positive on disk", ErrMalformedDocument)
	}
	return rev, nil
}

func decodeWorkspaces(dec *json.Decoder) ([]WorkspaceLocation, error) {
	tok, err := dec.Token()
	if err != nil {
		return nil, fmt.Errorf("%w: invalid JSON syntax", ErrMalformedDocument)
	}
	if tok == nil {
		return nil, fmt.Errorf("%w: null field", ErrMalformedDocument)
	}
	delim, ok := tok.(json.Delim)
	if !ok || delim != '[' {
		return nil, fmt.Errorf("%w: invalid field type for workspaces", ErrMalformedDocument)
	}

	workspaces := make([]WorkspaceLocation, 0)
	for dec.More() {
		if len(workspaces) >= MaxWorkspaces {
			return nil, fmt.Errorf("%w: workspace entries limit exceeded", ErrMalformedDocument)
		}
		loc, err := decodeWorkspaceLocation(dec)
		if err != nil {
			return nil, err
		}
		workspaces = append(workspaces, loc)
	}

	tok, err = dec.Token()
	if err != nil || tok != json.Delim(']') {
		return nil, fmt.Errorf("%w: expected end of workspaces array", ErrMalformedDocument)
	}
	return workspaces, nil
}

func decodeWorkspaceLocation(dec *json.Decoder) (WorkspaceLocation, error) {
	tok, err := dec.Token()
	if err != nil {
		return WorkspaceLocation{}, fmt.Errorf("%w: invalid JSON syntax", ErrMalformedDocument)
	}
	if tok == nil {
		return WorkspaceLocation{}, fmt.Errorf("%w: null workspace entry", ErrMalformedDocument)
	}
	delim, ok := tok.(json.Delim)
	if !ok || delim != '{' {
		return WorkspaceLocation{}, fmt.Errorf("%w: expected workspace object", ErrMalformedDocument)
	}

	seen := make(map[string]bool, 3)
	var loc WorkspaceLocation

	for dec.More() {
		tok, err := dec.Token()
		if err != nil {
			return WorkspaceLocation{}, fmt.Errorf("%w: invalid JSON syntax", ErrMalformedDocument)
		}
		key, ok := tok.(string)
		if !ok {
			return WorkspaceLocation{}, fmt.Errorf("%w: expected string key", ErrMalformedDocument)
		}
		if seen[key] {
			return WorkspaceLocation{}, fmt.Errorf("%w: duplicate field", ErrMalformedDocument)
		}
		seen[key] = true

		switch key {
		case "workspace_id":
			valTok, err := dec.Token()
			if err != nil {
				return WorkspaceLocation{}, fmt.Errorf("%w: invalid JSON syntax", ErrMalformedDocument)
			}
			if valTok == nil {
				return WorkspaceLocation{}, fmt.Errorf("%w: null field", ErrMalformedDocument)
			}
			s, ok := valTok.(string)
			if !ok {
				return WorkspaceLocation{}, fmt.Errorf("%w: invalid field type for workspace_id", ErrMalformedDocument)
			}
			if err := validateID(s, "workspace_id"); err != nil {
				return WorkspaceLocation{}, err
			}
			loc.WorkspaceID = s

		case "project_dir":
			valTok, err := dec.Token()
			if err != nil {
				return WorkspaceLocation{}, fmt.Errorf("%w: invalid JSON syntax", ErrMalformedDocument)
			}
			if valTok == nil {
				return WorkspaceLocation{}, fmt.Errorf("%w: null field", ErrMalformedDocument)
			}
			s, ok := valTok.(string)
			if !ok {
				return WorkspaceLocation{}, fmt.Errorf("%w: invalid field type for project_dir", ErrMalformedDocument)
			}
			if err := validatePath(s, "project_dir"); err != nil {
				return WorkspaceLocation{}, err
			}
			loc.ProjectDir = s

		case "runtime_state_dir":
			valTok, err := dec.Token()
			if err != nil {
				return WorkspaceLocation{}, fmt.Errorf("%w: invalid JSON syntax", ErrMalformedDocument)
			}
			if valTok == nil {
				return WorkspaceLocation{}, fmt.Errorf("%w: null field", ErrMalformedDocument)
			}
			s, ok := valTok.(string)
			if !ok {
				return WorkspaceLocation{}, fmt.Errorf("%w: invalid field type for runtime_state_dir", ErrMalformedDocument)
			}
			if err := validatePath(s, "runtime_state_dir"); err != nil {
				return WorkspaceLocation{}, err
			}
			loc.RuntimeStateDir = s

		default:
			return WorkspaceLocation{}, fmt.Errorf("%w: unknown field", ErrMalformedDocument)
		}
	}

	tok, err = dec.Token()
	if err != nil || tok != json.Delim('}') {
		return WorkspaceLocation{}, fmt.Errorf("%w: expected end of workspace object", ErrMalformedDocument)
	}

	if !seen["workspace_id"] || !seen["project_dir"] || !seen["runtime_state_dir"] {
		return WorkspaceLocation{}, fmt.Errorf("%w: missing required field", ErrMalformedDocument)
	}

	return loc, nil
}
