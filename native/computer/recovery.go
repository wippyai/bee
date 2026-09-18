// SPDX-License-Identifier: MIT
package computer

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"

	"github.com/wippyai/bee/native/internal/privatefile"
)

var ErrRecovery = errors.New("computer seat recovery unresolved")

type recoveryRecord struct {
	Revision int    `json:"revision"`
	Node     string `json:"node"`
	Resource string `json:"resource"`
	Pending  string `json:"pending"`
	Session  string `json:"session,omitempty"`
}
type recoveryState struct {
	file           *privatefile.File
	node, resource string
}

// One stable host-selected directory per physical seat, shared by replacement
// owners. Creating another directory is not recovery. Same-account code remains
// OS-authorized to alter this state; it is not a sandbox against the local user.
func newRecovery(dir, node, resource string) (*recoveryState, error) {
	f, err := privatefile.New(dir, "recovery.json", "recovery.lock")
	if err != nil {
		return nil, err
	}
	return &recoveryState{f, node, resource}, nil
}

func (s *recoveryState) decode(raw []byte) (recoveryRecord, error) {
	r := recoveryRecord{Revision: 1, Node: s.node, Resource: s.resource}
	if len(raw) == 0 {
		return r, nil
	}
	r = recoveryRecord{}
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if err := d.Decode(&r); err != nil {
		return r, ErrRecovery
	}
	var trailing interface{}
	if d.Decode(&trailing) != io.EOF || r.Revision != 1 || r.Node != s.node || r.Resource != s.resource || (r.Pending != "" && len(r.Pending) != 32) {
		return r, ErrRecovery
	}
	return r, nil
}

func (s *recoveryState) change(ctx context.Context, f func(*recoveryRecord) error) error {
	return s.file.ReadModifyWrite(ctx, 4096, func(raw []byte) ([]byte, error) {
		r, err := s.decode(raw)
		if err != nil {
			return nil, err
		}
		if err = f(&r); err != nil {
			return nil, err
		}
		return json.Marshal(r)
	})
}
func (s *recoveryState) available(ctx context.Context) error {
	return s.change(ctx, func(r *recoveryRecord) error {
		if r.Pending != "" {
			return ErrRecovery
		}
		return nil
	})
}
func (s *recoveryState) begin(ctx context.Context, session string) (string, error) {
	if session == "" || len(session) > 128 {
		return "", ErrRecovery
	}
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	token := hex.EncodeToString(b[:])
	err := s.change(ctx, func(r *recoveryRecord) error {
		if r.Pending != "" {
			return ErrRecovery
		}
		r.Pending = token
		r.Session = session
		return nil
	})
	if err != nil {
		return "", err
	}
	return token, nil
}
func (s *recoveryState) complete(ctx context.Context, token string) error {
	return s.change(ctx, func(r *recoveryRecord) error {
		if token == "" || r.Pending != token {
			return ErrRecovery
		}
		r.Pending = ""
		r.Session = ""
		return nil
	})
}

func (s *recoveryState) resolve(ctx context.Context, verify func(string) error) error {
	return s.change(ctx, func(r *recoveryRecord) error {
		if r.Pending == "" {
			return nil
		}
		if r.Session == "" || len(r.Session) > 128 {
			return ErrRecovery
		}
		if err := verify(r.Session); err != nil {
			return errors.Join(ErrRecovery, err)
		}
		r.Pending = ""
		r.Session = ""
		return nil
	})
}
