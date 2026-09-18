// SPDX-License-Identifier: MPL-2.0
// Bounded child-process protocol. Host admission belongs to the Bee owner.
package driver

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"image/png"
	"os"
	"runtime"
	"time"
)

type Action struct {
	Kind  string `json:"kind"`
	X     int    `json:"x,omitempty"`
	Y     int    `json:"y,omitempty"`
	ToX   int    `json:"to_x,omitempty"`
	ToY   int    `json:"to_y,omitempty"`
	Text  string `json:"text,omitempty"`
	Key   string `json:"key,omitempty"`
	Steps int    `json:"steps,omitempty"`
}
type Request struct {
	ID       int      `json:"id"`
	Endpoint string   `json:"endpoint,omitempty"`
	Op       string   `json:"op"`
	BasedOn  string   `json:"based_on,omitempty"`
	Actions  []Action `json:"actions,omitempty"`
}
type Reply struct {
	ID       int      `json:"id"`
	Endpoint string   `json:"endpoint,omitempty"`
	Session  string   `json:"session,omitempty"`
	Error    string   `json:"error,omitempty"`
	Frame    string   `json:"frame,omitempty"`
	Width    int      `json:"width,omitempty"`
	Height   int      `json:"height,omitempty"`
	Bytes    int      `json:"bytes,omitempty"`
	Outcomes []string `json:"outcomes,omitempty"`
}

func ident() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}
func Run() error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	if err := openNative(); err != nil {
		return err
	}
	defer closeNative()
	session, err := sessionIdentity()
	if err != nil {
		return err
	}
	endpoint := ident()
	// Fixed short lease for the POC; production requires owner-issued renewable grants.
	deadline := time.Now().Add(30 * time.Second)
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 4096), 64*1024)
	enc := json.NewEncoder(os.Stdout)
	frame := ""
	fw, fh := 0, 0
	lastID := 0
	lines := make(chan []byte)
	done := make(chan struct{})
	defer close(done)
	go func() {
		defer close(lines)
		for scanner.Scan() {
			line := append([]byte(nil), scanner.Bytes()...)
			select {
			case lines <- line:
			case <-done:
				return
			}
		}
	}()
	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()
	for {
		// Monitoring and native operations share this locked OS thread.
		var line []byte
		select {
		case <-ticker.C:
			if time.Now().After(deadline) {
				return errors.New("lease expired")
			}
			if _, _, err := size(); err != nil {
				return err
			}
			continue
		case next, ok := <-lines:
			if !ok {
				return scanner.Err()
			}
			line = next
		}
		if _, _, err := size(); err != nil {
			return err
		}
		var req Request
		if err := json.Unmarshal(line, &req); err != nil {
			return err
		}
		res := Reply{ID: req.ID, Endpoint: endpoint, Session: session}
		var payload []byte
		switch {
		case req.ID <= lastID:
			res.Error = "non-increasing request ID"
		case req.Op == "hello" && lastID == 0:
			lastID = req.ID
		case req.Endpoint != endpoint:
			res.Error = "endpoint retired or mismatched"
		case req.Op == "stop":
			frame = ""
			return enc.Encode(res)
		case time.Now().After(deadline):
			res.Error = "lease expired"
		default:
			lastID = req.ID
			switch req.Op {
			case "observe":
				w, h, err := size()
				if err != nil {
					res.Error = err.Error()
					break
				}
				im, err := captureNative(w, h)
				if err != nil {
					res.Error = err.Error()
					break
				}
				var b bytes.Buffer
				if err = png.Encode(&b, im); err != nil {
					res.Error = err.Error()
					break
				}
				if b.Len() > 16*1024*1024 {
					res.Error = "image exceeds transfer limit"
					break
				}
				frame = ident()
				fw, fh = w, h
				payload = b.Bytes()
				res.Frame, res.Width, res.Height, res.Bytes = frame, w, h, len(payload)
			case "act":
				w, h, err := size()
				if err != nil || frame == "" || req.BasedOn != frame || w != fw || h != fh {
					res.Error = "stale or invalid frame"
					break
				}
				if len(req.Actions) == 0 || len(req.Actions) > 32 {
					res.Error = "action batch limit"
					break
				}
				for _, a := range req.Actions {
					if err = validate(a, w, h); err != nil {
						res.Error = err.Error()
						break
					}
				}
				if res.Error != "" {
					break
				}
				frame = "" // Consume before effects; uncertain actions must not be replayed.
				failed := false
				for _, a := range req.Actions {
					if failed || time.Now().After(deadline) {
						res.Outcomes = append(res.Outcomes, "skipped")
						continue
					}
					if execute(a) {
						res.Outcomes = append(res.Outcomes, "injected")
					} else {
						res.Outcomes = append(res.Outcomes, "uncertain")
						failed = true
					}
				}
			default:
				res.Error = "unknown operation"
			}
		}
		if len(payload) > 0 {
			if time.Now().After(deadline) {
				return errors.New("lease expired before frame release")
			}
			if _, _, err := size(); err != nil {
				return err
			}
		}
		if err := enc.Encode(res); err != nil {
			return err
		}
		if len(payload) > 0 {
			if _, err := os.Stdout.Write(payload); err != nil {
				return err
			}
		}
	}
}
