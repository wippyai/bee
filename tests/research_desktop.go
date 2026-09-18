// SPDX-License-Identifier: MIT
// Bounded physical-terminal proof for the durable performance research view.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/charmbracelet/x/ansi"
	vt "github.com/charmbracelet/x/vt"
	"github.com/creack/pty"
)

const (
	researchSyncEnd  = "\x1b[?2026l"
	researchRawLimit = 16 << 20
)

type researchDesktop struct {
	cmd        *exec.Cmd
	terminal   *os.File
	cancel     context.CancelFunc
	emulator   *vt.SafeEmulator
	mu         sync.Mutex
	raw        []byte
	rawTrimmed bool
	pending    []byte
	latest     string
	frameSeq   uint64
	readDone   chan struct{}
	done       chan struct{}
	waitErr    error
	exited     bool
	quitSent   bool
	evidence   string
	artifact   string
	bootLabel  string
}

type researchMeasurementReport struct {
	Measurements map[string]struct {
		Measurement struct {
			Label   string    `json:"label"`
			Units   string    `json:"units"`
			Samples []float64 `json:"samples"`
		} `json:"measurement"`
	} `json:"measurements"`
}

type researchMedians struct {
	baseline  float64
	candidate float64
}

func checkResearchDesktop(root, runtime string, environment []string) error {
	root, err := filepath.Abs(root)
	if err != nil {
		return fmt.Errorf("resolve research workspace: %w", err)
	}
	evidence := filepath.Join(root, "research-desktop")
	if err := os.MkdirAll(filepath.Join(evidence, "frames"), 0700); err != nil {
		return fmt.Errorf("create private desktop evidence: %w", err)
	}

	medians, err := researchMeasurementMedians(filepath.Join(root, "run.log"))
	if err != nil {
		return err
	}
	if err := researchDesktopBoot(root, runtime, environment, evidence, "boot-1", medians, false); err != nil {
		return fmt.Errorf("first research desktop boot: %w", err)
	}
	if err := researchDesktopBoot(root, runtime, environment, evidence, "boot-2", medians, true); err != nil {
		return fmt.Errorf("restored research desktop boot: %w", err)
	}
	return nil
}

func researchMeasurementMedians(path string) (researchMedians, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return researchMedians{}, fmt.Errorf("read native measurement log %s: %w", path, err)
	}
	const prefix = "RESEARCH_MEASUREMENT_PASS "
	var reportLine string
	for _, line := range strings.Split(string(data), "\n") {
		if index := strings.Index(line, prefix); index >= 0 {
			reportLine = line[index+len(prefix):]
		}
	}
	if reportLine == "" {
		return researchMedians{}, fmt.Errorf("%s has no RESEARCH_MEASUREMENT_PASS report", path)
	}
	var report researchMeasurementReport
	if err := json.Unmarshal([]byte(reportLine), &report); err != nil {
		return researchMedians{}, fmt.Errorf("decode measurement report in %s: %w", path, err)
	}
	baseline, err := researchMeasurementMedian(path, report.Measurements, "baseline")
	if err != nil {
		return researchMedians{}, err
	}
	candidate, err := researchMeasurementMedian(path, report.Measurements, "candidate")
	if err != nil {
		return researchMedians{}, err
	}
	return researchMedians{baseline: baseline, candidate: candidate}, nil
}

func researchMeasurementMedian(path string, measurements map[string]struct {
	Measurement struct {
		Label   string    `json:"label"`
		Units   string    `json:"units"`
		Samples []float64 `json:"samples"`
	} `json:"measurement"`
}, label string) (float64, error) {
	record, ok := measurements[label]
	if !ok || record.Measurement.Label != label || record.Measurement.Units != "ns/op" {
		return 0, fmt.Errorf("%s has no valid %s ns/op measurement", path, label)
	}
	samples := record.Measurement.Samples
	if len(samples) != 7 {
		return 0, fmt.Errorf("%s %s has %d samples; want 7", path, label, len(samples))
	}
	for _, sample := range samples {
		if sample <= 0 || math.IsNaN(sample) || math.IsInf(sample, 0) {
			return 0, fmt.Errorf("%s %s contains an invalid sample %v", path, label, sample)
		}
	}
	sort.Float64s(samples)
	return samples[len(samples)/2], nil
}

func researchDesktopBoot(root, runtime string, environment []string, evidence, label string, medians researchMedians, requireRestore bool) (result error) {
	session, err := startResearchDesktop(root, runtime, environment, evidence, label)
	if err != nil {
		return err
	}
	defer func() {
		result = errors.Join(result, session.close())
	}()

	if err := session.waitFor("BEE", 20*time.Second); err != nil {
		return err
	}
	if err := session.saveFrame(label + "-ready"); err != nil {
		return err
	}

	if requireRestore {
		if err := session.waitFor("PERFORMANCE RESEARCH", 20*time.Second); err != nil {
			return fmt.Errorf("saved layout did not restore Performance Research: %w", err)
		}
		if err := session.saveFrame(label + "-restored"); err != nil {
			return err
		}
	} else if err := session.openResearch(); err != nil {
		return err
	}

	if err := session.waitDashboard(medians, label+" dashboard", 10*time.Second); err != nil {
		return err
	}
	if err := session.saveFrame(label + "-dashboard"); err != nil {
		return err
	}

	if !requireRestore {
		before := session.sequence()
		if err := session.resize(70, 24); err != nil {
			return err
		}
		if err := session.waitResponsive(before, medians, 5*time.Second); err != nil {
			return err
		}
		if err := session.saveFrame(label + "-resized-70x24"); err != nil {
			return err
		}
	}

	if err := session.quit(); err != nil {
		return err
	}
	return nil
}

func startResearchDesktop(root, runtime string, environment []string, evidence, label string) (*researchDesktop, error) {
	if !filepath.IsAbs(runtime) && strings.ContainsRune(runtime, filepath.Separator) {
		absolute, err := filepath.Abs(runtime)
		if err != nil {
			return nil, err
		}
		runtime = absolute
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	cmd := exec.CommandContext(ctx, runtime, "run", "bee", "--host", "bee:terminal", "--set", "registry.history_path="+filepath.Join(root, "registry.db"))
	cmd.Dir = root
	cmd.Env = researchEnvironment(environment)
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return nil
		}
		return cmd.Process.Signal(os.Interrupt)
	}
	cmd.WaitDelay = 2 * time.Second
	terminal, err := pty.StartWithSize(cmd, &pty.Winsize{Cols: 100, Rows: 32})
	if err != nil {
		cancel()
		return nil, fmt.Errorf("start runtime PTY: %w", err)
	}
	session := &researchDesktop{
		cmd: cmd, terminal: terminal, cancel: cancel,
		emulator: vt.NewSafeEmulator(100, 32), readDone: make(chan struct{}), done: make(chan struct{}),
		evidence: evidence, artifact: filepath.Join(evidence, label+".raw"), bootLabel: label,
	}
	go session.readOutput()
	go func() {
		err := cmd.Wait()
		session.mu.Lock()
		session.waitErr = err
		session.exited = true
		session.mu.Unlock()
		close(session.done)
	}()
	return session, nil
}

func researchEnvironment(environment []string) []string {
	if environment == nil {
		environment = os.Environ()
	}
	result := make([]string, 0, len(environment)+1)
	for _, value := range environment {
		key, _, ok := strings.Cut(value, "=")
		if ok && key == "TERM" {
			continue
		}
		result = append(result, value)
	}
	return append(result, "TERM=xterm-256color")
}

func (d *researchDesktop) readOutput() {
	defer close(d.readDone)
	buffer := make([]byte, 32*1024)
	for {
		n, err := d.terminal.Read(buffer)
		if n > 0 {
			d.recordOutput(buffer[:n])
		}
		if err != nil {
			return
		}
	}
}

func (d *researchDesktop) recordOutput(data []byte) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if len(data) >= researchRawLimit {
		d.raw = append(d.raw[:0], data[len(data)-researchRawLimit:]...)
		d.rawTrimmed = true
	} else {
		if excess := len(d.raw) + len(data) - researchRawLimit; excess > 0 {
			d.raw = append([]byte(nil), d.raw[excess:]...)
			d.rawTrimmed = true
		}
		d.raw = append(d.raw, data...)
	}
	d.pending = append(d.pending, data...)
	for {
		end := bytes.Index(d.pending, []byte(researchSyncEnd))
		if end < 0 {
			keep := len(researchSyncEnd) - 1
			if len(d.pending) > keep {
				safe := len(d.pending) - keep
				_, _ = d.emulator.Write(d.pending[:safe])
				d.pending = append(d.pending[:0], d.pending[safe:]...)
			}
			return
		}
		end += len(researchSyncEnd)
		_, _ = d.emulator.Write(d.pending[:end])
		d.pending = append(d.pending[:0], d.pending[end:]...)
		d.captureFrameLocked()
	}
}

func (d *researchDesktop) captureFrameLocked() {
	frame := ansi.Strip(d.emulator.Render())
	d.latest = frame
	d.frameSeq++
}

func (d *researchDesktop) snapshot() (string, uint64, int, int) {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.latest, d.frameSeq, d.emulator.Width(), d.emulator.Height()
}

func (d *researchDesktop) sequence() uint64 {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.frameSeq
}

func (d *researchDesktop) waitFor(text string, timeout time.Duration) error {
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	tick := time.NewTicker(20 * time.Millisecond)
	defer tick.Stop()
	for {
		frame, _, _, _ := d.snapshot()
		if strings.Contains(frame, text) {
			return nil
		}
		select {
		case <-d.done:
			d.mu.Lock()
			err := d.waitErr
			d.mu.Unlock()
			return fmt.Errorf("runtime exited before %q: %v\n%s", text, err, frame)
		case <-deadline.C:
			return fmt.Errorf("timed out waiting for %q\n%s", text, frame)
		case <-tick.C:
		}
	}
}

func (d *researchDesktop) openResearch() error {
	deadline := time.Now().Add(20 * time.Second)
	if err := d.click(3, 1); err != nil {
		return err
	}
	if err := d.clickLabel("Tools", deadline); err != nil {
		return fmt.Errorf("open Start > Tools: %w", err)
	}
	if err := d.clickLabel("Performance Research", deadline); err != nil {
		return fmt.Errorf("open Performance Research: %w", err)
	}
	remaining := time.Until(deadline)
	if remaining <= 0 {
		return errors.New("Start > Tools > Performance Research exceeded the 20-second bound")
	}
	if err := d.waitFor("PERFORMANCE RESEARCH", remaining); err != nil {
		return fmt.Errorf("Performance Research menu selection did not open the app: %w", err)
	}
	return nil
}

func (d *researchDesktop) clickLabel(label string, deadline time.Time) error {
	for time.Now().Before(deadline) {
		frame, _, _, _ := d.snapshot()
		if x, y, ok := researchFindLabel(frame, label); ok {
			return d.click(x, y)
		}
		select {
		case <-d.done:
			return errors.New("runtime exited while waiting for menu item")
		case <-time.After(20 * time.Millisecond):
		}
	}
	return fmt.Errorf("menu item %q did not appear within the 20-second bound", label)
}

func researchFindLabel(frame, label string) (int, int, bool) {
	for rowIndex, row := range strings.Split(frame, "\n") {
		if index := strings.Index(row, label); index >= 0 {
			return ansi.StringWidth(row[:index]) + 1, rowIndex + 1, true
		}
	}
	return 0, 0, false
}

func (d *researchDesktop) click(x, y int) error {
	if x < 1 || y < 1 {
		return fmt.Errorf("invalid SGR mouse position %d,%d", x, y)
	}
	press := []byte(fmt.Sprintf("\x1b[<0;%d;%dM", x, y))
	release := []byte(fmt.Sprintf("\x1b[<0;%d;%dm", x, y))
	if err := d.writeInput(press); err != nil {
		return err
	}
	if err := d.writeInput(release); err != nil {
		return err
	}
	return nil
}

func (d *researchDesktop) writeInput(data []byte) error {
	if _, err := d.terminal.Write(data); err != nil {
		return fmt.Errorf("write PTY input: %w", err)
	}
	return nil
}

var researchBaselineRow = regexp.MustCompile(`(?mi)^.*\bbaseline\s+INVALID\b[^\r\n]*$`)
var researchCandidateRow = regexp.MustCompile(`(?mi)^.*\bcandidate\s+CORRECT\b[^\r\n]*$`)
var researchMedianValue = regexp.MustCompile(`([0-9]+(?:\.[0-9]+)?)\s+ns/op`)
var researchSampleOrMedian = regexp.MustCompile(`(?mi)^.*(?:Samples:|Median:)[^\r\n]*$`)

func (d *researchDesktop) waitDashboard(want researchMedians, stage string, timeout time.Duration) error {
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	tick := time.NewTicker(20 * time.Millisecond)
	defer tick.Stop()
	for {
		frame, _, _, _ := d.snapshot()
		if strings.Contains(frame, "PERFORMANCE RESEARCH") &&
			researchBaselineRow.MatchString(frame) && researchCandidateRow.MatchString(frame) {
			return d.verifyDashboard(want, stage)
		}
		select {
		case <-d.done:
			return fmt.Errorf("runtime exited before measurement summaries appeared\n%s", frame)
		case <-deadline.C:
			return fmt.Errorf("timed out waiting for baseline and candidate summaries\n%s", frame)
		case <-tick.C:
		}
	}
}

func (d *researchDesktop) verifyDashboard(want researchMedians, stage string) error {
	frame, _, _, _ := d.snapshot()
	baselineLine := researchBaselineRow.FindString(frame)
	candidateLine := researchCandidateRow.FindString(frame)
	if !strings.Contains(frame, "PERFORMANCE RESEARCH") || baselineLine == "" || candidateLine == "" {
		return fmt.Errorf("%s screen is missing the PERFORMANCE RESEARCH baseline INVALID / candidate CORRECT ns/op summary\n%s", stage, frame)
	}
	if strings.Contains(strings.ToLower(frame), "fake1") {
		return fmt.Errorf("%s screen plots the forged fake1 measurement\n%s", stage, frame)
	}
	if strings.Contains(baselineLine, "%!") || strings.Contains(candidateLine, "%!") {
		return fmt.Errorf("%s numeric summary contains a Go formatting artifact\n%s", stage, frame)
	}
	for _, line := range researchSampleOrMedian.FindAllString(frame, -1) {
		if strings.Contains(line, "%!") {
			return fmt.Errorf("%s sample or median detail contains a Go formatting artifact\n%s", stage, frame)
		}
	}
	if err := researchCheckDisplayedMedian(baselineLine, want.baseline, "baseline", stage); err != nil {
		return err
	}
	if err := researchCheckDisplayedMedian(candidateLine, want.candidate, "candidate", stage); err != nil {
		return err
	}
	return nil
}

func researchCheckDisplayedMedian(line string, want float64, label, stage string) error {
	match := researchMedianValue.FindStringSubmatch(line)
	if len(match) != 2 {
		return fmt.Errorf("%s %s summary has no displayed ns/op median: %s", stage, label, line)
	}
	var displayed float64
	if _, err := fmt.Sscanf(match[1], "%f", &displayed); err != nil {
		return fmt.Errorf("parse displayed %s median %q: %w", label, match[1], err)
	}
	if math.Abs(displayed-want) > 0.051 {
		return fmt.Errorf("%s %s median %.1f ns/op differs from native run.log median %.4f ns/op: %s", stage, label, displayed, want, line)
	}
	return nil
}

func (d *researchDesktop) resize(columns, rows uint16) error {
	d.mu.Lock()
	if err := pty.Setsize(d.terminal, &pty.Winsize{Cols: columns, Rows: rows}); err != nil {
		d.mu.Unlock()
		return fmt.Errorf("resize terminal: %w", err)
	}
	d.emulator.Resize(int(columns), int(rows))
	d.latest = ""
	d.mu.Unlock()
	return nil
}

func (d *researchDesktop) waitResponsive(after uint64, want researchMedians, timeout time.Duration) error {
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	tick := time.NewTicker(20 * time.Millisecond)
	defer tick.Stop()
	for {
		frame, sequence, width, height := d.snapshot()
		if sequence > after && width == 70 && height == 24 &&
			strings.Contains(frame, "PERFORMANCE RESEARCH") &&
			strings.Contains(frame, "INVALID") && strings.Contains(frame, "CORRECT") &&
			strings.Contains(frame, "ns/op") {
			if err := d.verifyDashboard(want, "70x24 responsive"); err != nil {
				return err
			}
			return nil
		}
		select {
		case <-d.done:
			return errors.New("runtime exited before responsive research frame")
		case <-deadline.C:
			return fmt.Errorf("no responsive 70x24 research frame after resize\n%s", frame)
		case <-tick.C:
		}
	}
}

func (d *researchDesktop) saveFrame(name string) error {
	frame, _, _, _ := d.snapshot()
	path := filepath.Join(d.evidence, "frames", name+".txt")
	if err := os.WriteFile(path, []byte(frame), 0600); err != nil {
		return fmt.Errorf("save current frame %s: %w", name, err)
	}
	return nil
}

func (d *researchDesktop) quit() error {
	d.mu.Lock()
	exited := d.exited
	d.mu.Unlock()
	if !exited {
		if err := d.writeInput([]byte{0x11}); err != nil {
			return err
		}
		d.mu.Lock()
		d.quitSent = true
		d.mu.Unlock()
	}
	timer := time.NewTimer(10 * time.Second)
	defer timer.Stop()
	select {
	case <-d.done:
		d.mu.Lock()
		err := d.waitErr
		d.mu.Unlock()
		if err != nil {
			return fmt.Errorf("runtime did not exit cleanly after Ctrl+Q: %w", err)
		}
		return nil
	case <-timer.C:
		return errors.New("runtime did not stop after Ctrl+Q within 10 seconds")
	}
}

func (d *researchDesktop) close() (result error) {
	defer d.cancel()
	d.mu.Lock()
	exited := d.exited
	quitSent := d.quitSent
	d.mu.Unlock()
	if !exited {
		if !quitSent {
			if err := d.writeInput([]byte{0x11}); err != nil {
				result = errors.Join(result, err)
			}
		}
		select {
		case <-d.done:
		case <-time.After(3 * time.Second):
			d.cancel()
			select {
			case <-d.done:
			case <-time.After(5 * time.Second):
				result = errors.Join(result, errors.New("runtime process could not be stopped and joined"))
			}
		}
	}
	select {
	case <-d.readDone:
	case <-time.After(time.Second):
		_ = d.terminal.Close()
		select {
		case <-d.readDone:
		case <-time.After(2 * time.Second):
			result = errors.Join(result, errors.New("PTY output reader did not stop"))
		}
	}
	_ = d.terminal.Close()
	if err := d.writeArtifacts(); err != nil {
		result = errors.Join(result, err)
	}
	d.mu.Lock()
	waitErr := d.waitErr
	d.mu.Unlock()
	if waitErr != nil {
		result = errors.Join(result, fmt.Errorf("runtime exited with error: %w", waitErr))
	}
	return result
}

func (d *researchDesktop) writeArtifacts() error {
	d.mu.Lock()
	raw := append([]byte(nil), d.raw...)
	rawTrimmed := d.rawTrimmed
	if len(d.pending) > 0 {
		_, _ = d.emulator.Write(d.pending)
		d.pending = nil
	}
	d.mu.Unlock()
	if err := os.WriteFile(d.artifact, raw, 0600); err != nil {
		return fmt.Errorf("save raw PTY output for %s: %w", d.bootLabel, err)
	}
	if rawTrimmed {
		return fmt.Errorf("raw PTY output for %s exceeded the bounded 16 MiB capture", d.bootLabel)
	}
	return nil
}
