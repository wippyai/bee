// SPDX-License-Identifier: MIT
package launch

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/syncthing/notify"
)

type ownerLogForwarder struct {
	file   *os.File
	report io.Writer
	events chan notify.EventInfo
	cancel context.CancelFunc
	done   chan struct{}
	err    error
}

func beginOwnerLogForwarding(ctx context.Context, state, path string, owner startupSnapshot, report io.Writer, failed context.CancelFunc) (*ownerLogForwarder, error) {
	current, err := readStartup(state)
	if err != nil {
		return nil, err
	}
	if !current.belongsTo(owner.PID, owner.Launch) {
		return nil, errors.New("startup progress belongs to a different owner")
	}
	if current.Error != "" {
		return nil, errors.New(current.Error)
	}
	if current.Stopped {
		return nil, errors.New("owner has stopped")
	}
	if !current.Ready {
		return nil, errors.New("owner startup has not completed")
	}
	if report == nil {
		return nil, errors.New("owner log terminal output is unavailable")
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	forwarder := &ownerLogForwarder{file: file, report: report, events: make(chan notify.EventInfo, 1), done: make(chan struct{})}
	if err := notify.Watch(path, forwarder.events, notify.Write); err != nil {
		return nil, errors.Join(err, file.Close())
	}
	if _, err := file.Seek(0, io.SeekEnd); err != nil {
		notify.Stop(forwarder.events)
		return nil, errors.Join(err, file.Close())
	}
	ctx, forwarder.cancel = context.WithCancel(ctx)
	go func() {
		defer close(forwarder.done)
		defer notify.Stop(forwarder.events)
		defer func() { forwarder.err = errors.Join(forwarder.err, file.Close()) }()
		for {
			select {
			case <-ctx.Done():
				return
			case <-forwarder.events:
				if _, err := io.Copy(forwarder.report, forwarder.file); err != nil {
					forwarder.err = fmt.Errorf("forward owner log: %w", err)
					failed()
					return
				}
			}
		}
	}()
	return forwarder, nil
}

func (forwarder *ownerLogForwarder) stop() error {
	forwarder.cancel()
	<-forwarder.done
	return forwarder.err
}
