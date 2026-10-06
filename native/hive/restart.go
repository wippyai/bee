// SPDX-License-Identifier: MIT

package hive

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// pollInterval is how often a running bee compares the machine's hive file
// with the hive it started in.
const pollInterval = time.Second

// networkChanged reports whether the hive on disk differs from applied in what
// a running node cannot change in place: the secret, the address other
// machines reach it at, or the existence of a hive at all.
func networkChanged(applied *Hive, current *Hive) bool {
	if current == nil {
		return false
	}
	return applied == nil || applied.Secret != current.Secret || applied.Advertise != current.Advertise
}

// hiveWatch restarts the bee when the machine's hive changes under it. The
// runtime binds its cluster transport at start, so a joined hive reaches a
// running bee through a clean restart: the bee stops, then starts again
// as the same command in the same folder, and displays reconnect.
type hiveWatch struct {
	dir       string
	applied   *Hive
	interval  time.Duration
	interrupt func()

	restart bool
	mu      sync.Mutex
	stop    context.CancelFunc
	done    sync.WaitGroup
}

func (w *hiveWatch) start() {
	ctx, cancel := context.WithCancel(context.Background())
	w.stop = cancel
	w.done.Add(1)
	go func() {
		defer w.done.Done()
		w.run(ctx)
	}()
}

func (w *hiveWatch) close() {
	if w.stop != nil {
		w.stop()
	}
	w.done.Wait()
}

// restartRequested reports whether the watch asked the bee to stop for a restart.
func (w *hiveWatch) restartRequested() bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.restart
}

func (w *hiveWatch) run(ctx context.Context) {
	ticker := time.NewTicker(w.interval)
	defer ticker.Stop()
	var seen os.FileInfo
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
		info, err := os.Stat(filepath.Join(w.dir, hiveFile))
		if err != nil || (seen != nil && info.ModTime().Equal(seen.ModTime()) && info.Size() == seen.Size()) {
			continue
		}
		seen = info
		current, err := ReadHive(w.dir)
		if err != nil || !networkChanged(w.applied, current) {
			continue
		}
		w.mu.Lock()
		w.restart = true
		w.mu.Unlock()
		w.interrupt()
		return
	}
}

// relaunch replaces the process with the command it was started with.
func relaunch() error {
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	return replaceProcess(executable, os.Args)
}

var errRelaunchUnsupported = errors.New("bee hive: this system cannot restart a bee in place; start it again to use the joined hive")
