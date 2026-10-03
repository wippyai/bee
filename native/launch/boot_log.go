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
	"strings"
	"sync"
	"time"

	"github.com/wippyai/runtime/api/boot"
	"github.com/wippyai/runtime/api/event"
	"github.com/wippyai/runtime/api/logs"
	"github.com/wippyai/runtime/cmd/app"
	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
)

const bootLogVariable = "BEE_BOOT_LOG_DIR"

var _ app.BootLogger = (*Host)(nil)

// BootLogger supplies early runner phases before native components are loaded.
func (host *Host) BootLogger() *zap.Logger {
	if host.bootLog == nil {
		return nil
	}
	return host.bootLog.logger
}

func bootLoggingConfig(original boot.Config) boot.Config {
	sections := make(map[string]map[string]any)
	for _, key := range original.Keys() {
		section, field, found := strings.Cut(key, ".")
		if !found {
			continue
		}
		value, ok := original.Get(key)
		if !ok {
			continue
		}
		if sections[section] == nil {
			sections[section] = make(map[string]any)
		}
		sections[section][field] = value
	}
	if sections["logmanager"] == nil {
		sections["logmanager"] = make(map[string]any)
	}
	sections["logmanager"]["stream_to_events"] = true
	var options []boot.ConfigOption
	for section, fields := range sections {
		options = append(options, boot.WithSection(section, fields))
	}
	return boot.NewConfig(options...)
}

type bootLogKey struct{}
type bootLog struct {
	logger       *zap.Logger
	file         *os.File
	output       io.Writer
	failure      error
	bus          event.Bus
	subscription event.SubscriberID
	done         chan struct{}
	events       chan event.Event
	once         sync.Once
}

func newBootLog(directory string) (*bootLog, error) {
	if directory == "" {
		return nil, nil
	}
	if !filepath.IsAbs(directory) {
		return nil, errors.New("boot log directory must be absolute")
	}
	file, err := os.CreateTemp(directory, fmt.Sprintf("boot-%d-*.jsonl", os.Getpid()))
	if err != nil {
		return nil, err
	}
	encoder := zapcore.NewJSONEncoder(zapcore.EncoderConfig{
		TimeKey: "time_ns", MessageKey: "message", NameKey: "logger", LineEnding: zapcore.DefaultLineEnding,
		EncodeTime: func(value time.Time, output zapcore.PrimitiveArrayEncoder) { output.AppendInt64(value.UnixNano()) },
	})
	logger := zap.New(zapcore.NewCore(encoder, zapcore.AddSync(file), zap.DebugLevel)).Named("bee.boot").With(zap.Int("pid", os.Getpid()))
	return &bootLog{logger: logger, file: file}, nil
}

func (b *bootLog) phase(phase, stage string) {
	if b != nil {
		b.logger.Info("Boot phase", zap.String("phase", phase), zap.String("stage", stage))
	}
}

func bootPhase(ctx context.Context, phase, stage string) {
	log, _ := ctx.Value(bootLogKey{}).(*bootLog)
	log.phase(phase, stage)
}

// The runtime's event log carries its original emission timestamp even when
// stdout logging is silent. The diagnostic sink retains only boot messages
// and phase fields, without retaining arbitrary log payloads.
func (b *bootLog) capture(value event.Event) error {
	var record struct {
		Entry struct {
			Message string `json:"message"`
			Time    int64  `json:"time"`
		} `json:"entry"`
		Fields []struct {
			Key    string `json:"key"`
			String string `json:"string"`
			Int    int64  `json:"int"`
		} `json:"fields"`
	}
	data, err := json.Marshal(value.Data)
	if err != nil || json.Unmarshal(data, &record) != nil {
		return nil
	}
	if b.output != nil && record.Entry.Message == "Retained application restoration failed" {
		fields := make(map[string]string)
		for _, field := range record.Fields {
			fields[field.Key] = field.String
		}
		_, err := fmt.Fprintf(b.output, "Retained application restoration failed: %s [workspace=%s, instance=%s, definition=%s]\n",
			fields["error"], fields["workspace_id"], fields["instance_id"], fields["definition_id"])
		return err
	}
	if b.file == nil {
		return nil
	}
	phases := map[string]string{
		"components loaded successfully":          "runtime_loaded",
		"loading entries from lock file":          "registry_load_begin",
		"loaded entries":                          "registry_decoded",
		"creating baseline state from entries":    "registry_baseline_begin",
		"baseline state created":                  "registry_baseline_end",
		"applying change set to registry":         "registry_apply_begin",
		"entries applied to registry":             "registry_apply_end",
		"waiting for boot listener readiness":     "owners_readiness_begin",
		"boot listeners ready":                    "owners_readiness_end",
		"entries loaded to registry successfully": "registry_ready",
	}
	phase, known := phases[record.Entry.Message]
	if !known && record.Entry.Message != "Boot phase" {
		return nil
	}
	fields := []zap.Field{zap.Int64("origin_ns", record.Entry.Time)}
	if known {
		fields = append(fields, zap.String("phase", phase), zap.String("stage", "point"))
	}
	for _, field := range record.Fields {
		switch field.Key {
		case "pid":
			fields = append(fields, zap.String("actor", field.String))
		case "phase", "stage", "owner":
			if !known {
				fields = append(fields, zap.String(field.Key, field.String))
			}
		case "elapsed_ms":
			if !known {
				fields = append(fields, zap.Int64(field.Key, field.Int))
			}
		}
	}
	b.logger.Info("Boot phase", fields...)
	return nil
}

func (b *bootLog) subscribe(ctx context.Context) error {
	if b == nil {
		return nil
	}
	bus := event.GetBus(ctx)
	if bus == nil {
		return errors.New("boot log requires the runtime event bus")
	}
	events := make(chan event.Event, 1024)
	subscriber, err := bus.SubscribeP(ctx, logs.System, logs.Entry, events)
	if err != nil {
		return err
	}
	b.bus, b.subscription, b.done = bus, subscriber, make(chan struct{})
	go func() {
		defer close(b.done)
		for value := range events {
			b.failure = errors.Join(b.failure, b.capture(value))
		}
	}()
	// Unsubscribe is the send barrier; closing this channel afterwards drains
	// all accepted phase events before closing the file.
	b.events = events
	return nil
}

func (b *bootLog) close() error {
	if b == nil {
		return nil
	}
	b.once.Do(func() {
		if b.bus != nil {
			b.bus.Unsubscribe(context.Background(), b.subscription)
			close(b.events)
			<-b.done
		}
		b.failure = errors.Join(b.failure, b.logger.Sync())
		if b.file != nil {
			b.failure = errors.Join(b.failure, b.file.Close())
		}
	})
	return b.failure
}
