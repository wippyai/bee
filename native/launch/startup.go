// SPDX-License-Identifier: MIT
package launch

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/syncthing/notify"
	"github.com/wippyai/bee/native/internal/privatefile"
	envapi "github.com/wippyai/runtime/api/env"
)

const startupFile = "progress.json"
const startupDirectory = "startup"
const ownerProgressLogVariable = "BEE_INTERNAL_OWNER_PROGRESS_LOG"
const startupProgressPrefix = "BEE_STARTUP_PROGRESS "

type startupSnapshot struct {
	Version  int    `json:"version"`
	PID      int    `json:"pid"`
	Launch   string `json:"launch"`
	Sequence uint64 `json:"sequence"`
	Phase    string `json:"phase"`
	Ready    bool   `json:"ready"`
	Stopped  bool   `json:"stopped"`
	Error    string `json:"error,omitempty"`
}

func (s startupSnapshot) belongsTo(pid int, launch string) bool {
	return s.Version == 1 && s.PID == pid && s.Launch == launch
}

func readStartup(state string) (startupSnapshot, error) {
	file, err := privatefile.New(filepath.Join(state, startupDirectory), startupFile, ".read.lock")
	if err != nil {
		return startupSnapshot{}, err
	}
	data, err := file.Read(context.Background(), 65536)
	if err != nil {
		return startupSnapshot{}, err
	}
	var s startupSnapshot
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&s); err != nil {
		return s, err
	}
	if s.Version != 1 || s.PID <= 0 || s.Sequence == 0 || len(s.Launch) > 128 || s.Phase == "" || len(s.Phase) > 256 || strings.ContainsAny(s.Phase, "\r\n\x00") || len(s.Error) > 32768 {
		return s, errors.New("invalid Bee startup progress")
	}
	if err := decoder.Decode(new(json.RawMessage)); err != io.EOF {
		return s, errors.New("trailing Bee startup progress")
	}
	return s, nil
}

type startupMonitor struct {
	mutex        sync.Mutex
	snapshot     startupSnapshot
	state        string
	log          string
	offset       int64
	pending      string
	events       chan notify.EventInfo
	cancel       context.CancelFunc
	done         chan struct{}
	dirty        bool
	upgraded     map[string]string
	publications map[string]uint64
	cacheReads   map[string]bool
}

func beginStartup(ctx context.Context, state, launch, log string) (*startupMonitor, error) {
	if err := privatefile.EnsurePrivateDir(filepath.Join(state, startupDirectory)); err != nil {
		return nil, err
	}
	cache := filepath.Join(state, "cache", "lua")
	if err := os.MkdirAll(cache, 0700); err != nil {
		return nil, err
	}
	if log != "" && (filepath.Dir(log) != state || !strings.HasPrefix(filepath.Base(log), "owner-") || filepath.Ext(log) != ".log") {
		return nil, errors.New("owner progress log is outside its state")
	}
	ctx, cancel := context.WithCancel(ctx)
	m := &startupMonitor{snapshot: startupSnapshot{Version: 1, PID: os.Getpid(), Launch: launch, Sequence: 1, Phase: "Loading application"}, state: state, log: log, events: make(chan notify.EventInfo, 4096), cancel: cancel, done: make(chan struct{}), dirty: true, upgraded: map[string]string{}, publications: map[string]uint64{}, cacheReads: map[string]bool{}}
	if err := notify.Watch(cache+string(os.PathSeparator)+"...", m.events, cacheProgressEvents()...); err != nil {
		cancel()
		return nil, err
	}
	if err := notify.Watch(state, m.events, notify.Write, notify.Create); err != nil {
		notify.Stop(m.events)
		cancel()
		return nil, err
	}
	if err := m.flush(); err != nil {
		notify.Stop(m.events)
		cancel()
		return nil, err
	}
	go m.run(ctx)
	return m, nil
}
func (m *startupMonitor) advance(phase string) {
	m.mutex.Lock()
	defer m.mutex.Unlock()
	if m.snapshot.Ready || m.snapshot.Stopped {
		return
	}
	m.snapshot.Sequence++
	if phase != "" {
		m.snapshot.Phase = phase
	}
	m.dirty = true
}
func (m *startupMonitor) cacheProgress(path string, read bool) {
	m.mutex.Lock()
	if m.snapshot.Ready || m.snapshot.Stopped || (read && m.cacheReads[path]) {
		m.mutex.Unlock()
		return
	}
	if read {
		m.cacheReads[path] = true
	} else {
		delete(m.cacheReads, path)
	}
	m.mutex.Unlock()
	m.advance("")
}
func (m *startupMonitor) publish(phase string) error {
	if phase == "" || len(phase) > 256 || strings.ContainsAny(phase, "\r\n\x00") {
		return errors.New("invalid migration progress")
	}
	label, kind, revision := "", "", ""
	for _, prefix := range []string{"Checking data: ", "Upgrading data: ", "Upgraded data: ", "Applied data: "} {
		if rest, ok := strings.CutPrefix(phase, prefix); ok {
			fields := strings.Fields(rest)
			if len(fields) == 0 || len(fields) > 2 {
				return errors.New("missing migration owner")
			}
			label, kind = fields[0], prefix
			if len(fields) == 2 {
				revision = fields[1]
			}
			break
		}
	}
	if label == "" || len(label) > 64 {
		return errors.New("invalid migration owner")
	}
	for _, c := range label {
		if (c < 'a' || c > 'z') && c != '_' && c != '-' {
			return errors.New("invalid migration owner")
		}
	}
	checkpoint := uint64(0)
	if revision != "" {
		separator := "->"
		if kind == "Checking data: " {
			separator = "/"
		}
		if kind == "Applied data: " {
			value, err := strconv.ParseUint(revision, 10, 32)
			if err != nil {
				return errors.New("invalid migration revision")
			}
			checkpoint = value
		} else {
			before, after, ok := strings.Cut(revision, separator)
			if !ok {
				return errors.New("invalid migration revisions")
			}
			beforeValue, err := strconv.ParseUint(before, 10, 32)
			if err != nil {
				return errors.New("invalid migration revision")
			}
			afterValue, err := strconv.ParseUint(after, 10, 32)
			if err != nil {
				return errors.New("invalid migration revision")
			}
			checkpoint = afterValue
			if kind == "Checking data: " {
				checkpoint = beforeValue
			}
		}
	}
	m.mutex.Lock()
	defer m.mutex.Unlock()
	if m.snapshot.Ready || m.snapshot.Stopped {
		return nil
	}
	if kind == "Upgraded data: " && revision == "" {
		checkpoint = m.publications["Upgrading data: "+label]
	}
	key := kind + label
	if previous, seen := m.publications[key]; seen && checkpoint <= previous {
		return nil
	}
	m.publications[key] = checkpoint
	m.snapshot.Sequence++
	m.snapshot.Phase = phase
	m.dirty = true
	if m.log != "" {
		_, _ = fmt.Fprintf(os.Stderr, "BEE_STARTUP_PHASE %d %s\n", time.Now().UnixMilli(), phase)
	}
	if kind == "Upgrading data: " {
		m.upgraded[label] = phase
	}
	if kind == "Upgraded data: " {
		delete(m.upgraded, label)
	}
	if kind != "Upgrading data: " {
		active := ""
		for owner := range m.upgraded {
			if active == "" || owner < active {
				active = owner
			}
		}
		if active != "" {
			m.snapshot.Phase = m.upgraded[active]
		}
	}
	return nil
}
func (m *startupMonitor) flush() error {
	m.mutex.Lock()
	defer m.mutex.Unlock()
	if !m.dirty {
		return nil
	}
	data, err := json.Marshal(m.snapshot)
	if err != nil {
		return err
	}
	if err := privatefile.WriteAtomic(filepath.Join(m.state, startupDirectory, startupFile), data); err != nil {
		return err
	}
	m.dirty = false
	return nil
}
func (m *startupMonitor) logProgress() error {
	if m.log == "" {
		return nil
	}
	file, err := os.Open(m.log)
	if err != nil {
		return err
	}
	defer file.Close()
	if _, err := file.Seek(m.offset, io.SeekStart); err != nil {
		return err
	}
	data, err := io.ReadAll(io.LimitReader(file, 64*1024))
	if err != nil {
		return err
	}
	m.offset += int64(len(data))
	m.pending += string(data)
	for {
		line, rest, found := strings.Cut(m.pending, "\n")
		if !found {
			break
		}
		m.pending = rest
		line = strings.TrimSpace(line)
		if phase, ok := strings.CutPrefix(line, startupProgressPrefix); ok && phase != "" && len(phase) <= 256 && !strings.ContainsAny(phase, "\r\n\x00") {
			if err := m.publish(phase); err != nil {
				return err
			}
		}
		if detail, ok := strings.CutPrefix(line, startupFailurePrefix); ok {
			failure, err := decodeStartupFailure(detail)
			if err != nil {
				return fmt.Errorf("decode owner startup failure: %w", err)
			}
			m.mutex.Lock()
			m.snapshot.Error = failure.detail()
			m.dirty = true
			m.mutex.Unlock()
		}
	}
	if len(m.pending) > 1024*1024 {
		return errors.New("owner startup log line exceeds 1048576 bytes")
	}
	return nil
}
func (m *startupMonitor) run(ctx context.Context) {
	defer close(m.done)
	defer notify.Stop(m.events)
	tick := time.NewTicker(100 * time.Millisecond)
	defer tick.Stop()
	cache := filepath.Join(m.state, "cache", "lua") + string(os.PathSeparator)
	for {
		select {
		case <-ctx.Done():
			return
		case event := <-m.events:
			if event == nil {
				continue
			}
			path := event.Path()
			if strings.HasPrefix(path, cache) {
				m.cacheProgress(path, cacheVerificationRead(event.Event()))
			}
			name := filepath.Base(path)
			m.mutex.Lock()
			databasePhase := ""
			for label := range m.upgraded {
				base := strings.TrimSuffix(label, "s")
				if label == "thread" {
					base = "threads"
				}
				if label == "sync" && strings.HasPrefix(name, "node.db") {
					databasePhase = m.upgraded[label]
					break
				}
				if strings.HasPrefix(name, base+".db") || strings.HasPrefix(name, label+".db") || strings.HasPrefix(name, label+"s.db") {
					databasePhase = m.upgraded[label]
					break
				}
			}
			m.mutex.Unlock()
			if databasePhase != "" {
				m.advance(databasePhase)
			}
		case <-tick.C:
			if err := m.logProgress(); err != nil {
				m.fail(err)
				return
			}
			if err := m.flush(); err != nil {
				m.fail(err)
				return
			}
			m.mutex.Lock()
			ready := m.snapshot.Ready
			m.mutex.Unlock()
			if ready {
				return
			}
		}
	}
}
func (m *startupMonitor) fail(err error) {
	m.mutex.Lock()
	m.snapshot.Error = "Report Bee startup progress: " + err.Error()
	m.dirty = true
	m.mutex.Unlock()
	_ = m.flush()
}
func (m *startupMonitor) stop() error {
	m.cancel()
	<-m.done
	logError := m.logProgress()
	m.mutex.Lock()
	m.snapshot.Stopped = true
	m.dirty = true
	m.mutex.Unlock()
	return errors.Join(logError, m.flush())
}
func (m *startupMonitor) Get(_ context.Context, name string) (string, error) {
	m.mutex.Lock()
	defer m.mutex.Unlock()
	switch name {
	case "sequence":
		return strconv.FormatUint(m.snapshot.Sequence, 10), nil
	case "phase":
		return m.snapshot.Phase, nil
	case "progress":
		if m.snapshot.Ready || m.snapshot.Stopped {
			return "", nil
		}
		return m.snapshot.Phase, nil
	default:
		return "", envapi.ErrVariableNotFound
	}
}
func (m *startupMonitor) Set(_ context.Context, name, value string) error {
	if name == "progress" {
		return m.publish(value)
	}
	if name != "phase" {
		return errors.New("invalid startup progress field")
	}
	phases := map[string]string{"booting": "Starting workspace", "host_leasing": "Opening workspace host", "host_attaching": "Attaching workspace host", "client_boot": "Starting desktop", "admitting": "Admitting desktop", "rendering": "Rendering desktop", "running": "Bee ready"}
	phase, ok := phases[value]
	if !ok {
		return errors.New("invalid startup phase")
	}
	m.advance(phase)
	if value == "running" {
		m.mutex.Lock()
		m.snapshot.Ready = true
		m.dirty = true
		m.mutex.Unlock()
	}
	return m.flush()
}
func (*startupMonitor) Delete(context.Context, string) error {
	return errors.New("startup progress cannot be deleted")
}
func (m *startupMonitor) List(ctx context.Context) (map[string]string, error) {
	phase, _ := m.Get(ctx, "phase")
	sequence, _ := m.Get(ctx, "sequence")
	return map[string]string{"phase": phase, "sequence": sequence}, nil
}

type startupLine struct {
	report io.Writer
	phase  string
}

func (line *startupLine) show(phase string) error {
	if line.report == nil || line.phase == phase {
		return nil
	}
	if _, err := fmt.Fprintf(line.report, "\r\x1b[2K%s…", phase); err != nil {
		return err
	}
	line.phase = phase
	return nil
}

func (line *startupLine) clear() error {
	if line.phase == "" {
		return nil
	}
	if _, err := io.WriteString(line.report, "\r\x1b[2K"); err != nil {
		return err
	}
	line.phase = ""
	return nil
}

func observeStartup(state string, previous startupSnapshot, report *startupLine) func() error {
	return func() error {
		s, err := readStartup(state)
		if errors.Is(err, os.ErrNotExist) {
			s = startupSnapshot{}
		} else if err != nil {
			return err
		}
		if s.PID == previous.PID && s.Launch == previous.Launch {
			s = startupSnapshot{}
		}
		if s.Error != "" {
			return errors.New(s.Error)
		}
		if s.Stopped && !s.Ready {
			return fmt.Errorf("Bee owner exited during %s", s.Phase)
		}
		if s.Version == 1 && !s.Ready && report != nil {
			return report.show(s.Phase)
		}
		return nil
	}
}
