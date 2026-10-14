// SPDX-License-Identifier: MIT

// Package jsonwire validates bounded JSON and decodes typed object contracts.
package jsonwire

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"reflect"
	"strings"
	"unicode/utf8"
)

const maxDepth = 32

var ErrInvalidObject = errors.New("JSON object does not match its contract")

// Validate requires one bounded JSON value with no duplicate object members.
func Validate(data []byte, maxBytes int) error {
	if maxBytes < 1 || len(data) == 0 || len(data) > maxBytes || !utf8.Valid(data) {
		return ErrInvalidObject
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	first, err := decoder.Token()
	if err != nil {
		return ErrInvalidObject
	}
	if err := scanValue(decoder, first, 0); err != nil {
		return err
	}
	if _, err := decoder.Token(); err != io.EOF {
		return fmt.Errorf("%w: trailing JSON value", ErrInvalidObject)
	}
	return nil
}

// DecodeObject requires one bounded, duplicate-free JSON object with exact
// field names and every named required field present and non-null.
func DecodeObject[T any](data []byte, maxBytes int, required ...string) (T, error) {
	var zero T
	typeOf := reflect.TypeOf(zero)
	if typeOf == nil || typeOf.Kind() != reflect.Struct {
		return zero, fmt.Errorf("%w: destination must be a struct", ErrInvalidObject)
	}
	allowed, err := objectFields(typeOf)
	if err != nil {
		return zero, err
	}
	if err := Validate(data, maxBytes); err != nil {
		return zero, err
	}
	fields := make(map[string]json.RawMessage)
	if err := json.Unmarshal(data, &fields); err != nil || fields == nil {
		return zero, fmt.Errorf("%w: expected an object", ErrInvalidObject)
	}
	for name := range fields {
		if _, ok := allowed[name]; !ok {
			return zero, fmt.Errorf("%w: unknown field %q", ErrInvalidObject, name)
		}
	}
	for _, name := range required {
		if _, ok := allowed[name]; !ok {
			return zero, fmt.Errorf("%w: required field %q is not declared", ErrInvalidObject, name)
		}
		value, ok := fields[name]
		if !ok || bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return zero, fmt.Errorf("%w: required field %q is missing", ErrInvalidObject, name)
		}
	}

	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&zero); err != nil {
		return zero, fmt.Errorf("%w: %v", ErrInvalidObject, err)
	}
	return zero, nil
}

func objectFields(value reflect.Type) (map[string]struct{}, error) {
	fields := make(map[string]struct{}, value.NumField())
	for index := 0; index < value.NumField(); index++ {
		field := value.Field(index)
		if field.PkgPath != "" {
			continue
		}
		tag := field.Tag.Get("json")
		name, _, _ := strings.Cut(tag, ",")
		if name == "-" {
			continue
		}
		if name == "" {
			if field.Anonymous {
				nested := field.Type
				if nested.Kind() == reflect.Pointer {
					nested = nested.Elem()
				}
				if nested.Kind() == reflect.Struct {
					children, err := objectFields(nested)
					if err != nil {
						return nil, err
					}
					for child := range children {
						if _, exists := fields[child]; exists {
							return nil, fmt.Errorf("%w: ambiguous field %q", ErrInvalidObject, child)
						}
						fields[child] = struct{}{}
					}
					continue
				}
			}
			name = field.Name
		}
		if _, exists := fields[name]; exists {
			return nil, fmt.Errorf("%w: ambiguous field %q", ErrInvalidObject, name)
		}
		fields[name] = struct{}{}
	}
	return fields, nil
}

func scanValue(decoder *json.Decoder, token json.Token, depth int) error {
	if depth > maxDepth {
		return ErrInvalidObject
	}
	delimiter, ok := token.(json.Delim)
	if !ok {
		return nil
	}
	switch delimiter {
	case '{':
		keys := make(map[string]struct{})
		for decoder.More() {
			token, err := decoder.Token()
			name, ok := token.(string)
			if err != nil || !ok {
				return ErrInvalidObject
			}
			if _, exists := keys[name]; exists {
				return fmt.Errorf("%w: duplicate field %q", ErrInvalidObject, name)
			}
			keys[name] = struct{}{}
			value, err := decoder.Token()
			if err != nil {
				return ErrInvalidObject
			}
			if err := scanValue(decoder, value, depth+1); err != nil {
				return err
			}
		}
		end, err := decoder.Token()
		if err != nil || end != json.Delim('}') {
			return ErrInvalidObject
		}
	case '[':
		for decoder.More() {
			value, err := decoder.Token()
			if err != nil {
				return ErrInvalidObject
			}
			if err := scanValue(decoder, value, depth+1); err != nil {
				return err
			}
		}
		end, err := decoder.Token()
		if err != nil || end != json.Delim(']') {
			return ErrInvalidObject
		}
	default:
		return ErrInvalidObject
	}
	return nil
}
