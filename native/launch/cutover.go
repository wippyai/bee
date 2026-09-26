// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const (
	// cutoverLedgerName records the retained previous binary and the
	// confirmed candidate digest of the last cutover, so a rollback boots
	// a verified binary.
	cutoverLedgerName = "cutover.json"
	// cutoverPreviousName is the retained previous executable beside the
	// ledger. One generation is kept: enough for one-step rollback.
	cutoverPreviousName = "previous-bee"
	// cutoverSelfTestTimeout bounds the candidate readiness self-test.
	cutoverSelfTestTimeout = time.Minute
)

// errOlderOwnerProtocol signals that the running owner speaks an older
// client protocol than this binary. The cutover answers it with the
// retained previous binary's stop instead of this binary's client route.
var errOlderOwnerProtocol = errors.New("the running owner uses an older client protocol")

// CutoverRequest moves the running owner to a candidate executable. Digest
// is the person's explicit confirmation of the exact candidate binary: the
// cutover refuses anything else.
type CutoverRequest struct {
	State           string
	Dir             string
	Candidate       string
	ConfirmedDigest string
}

// CutoverResult names the retained previous binary and the verified digest
// of the candidate the owner now runs.
type CutoverResult struct {
	Previous string
	Digest   string
}

// cutoverSeams are the side effects a native cutover needs. Production
// supplies the real ones; tests substitute fakes to prove the sequence.
type cutoverSeams struct {
	// stopOld asks the running owner to drain over the authenticated
	// client channel.
	stopOld func(ctx context.Context, state, dir string) error
	// stopOldCompatible issues the same stop through an older binary when
	// this binary cannot speak to the running owner. It may be nil when no
	// older binary is retained.
	stopOldCompatible func(ctx context.Context, state, previous string) error
	// waitReleased waits until no owner holds the state lock.
	waitReleased func(ctx context.Context, state string) error
	// start launches executable as a detached owner and waits for its
	// readiness publication.
	start func(ctx context.Context, state, dir, executable string) error
	// currentExecutable is the running helper binary to retain.
	currentExecutable func() (string, error)
}

// runCutover verifies the person-confirmed candidate, drains the running
// owner, hands the state lock to the candidate and keeps the previous binary
// for one-step rollback. A candidate that fails to boot falls back to the
// retained previous binary automatically.
func runCutover(ctx context.Context, req CutoverRequest, seams cutoverSeams) (CutoverResult, error) {
	if ctx == nil {
		return CutoverResult{}, errors.New("native cutover requires a context")
	}
	if err := ctx.Err(); err != nil {
		return CutoverResult{}, err
	}
	if !filepath.IsAbs(req.State) || !filepath.IsAbs(req.Dir) {
		return CutoverResult{}, errors.New("native cutover requires absolute state and project directories")
	}
	if seams.stopOld == nil || seams.waitReleased == nil || seams.start == nil || seams.currentExecutable == nil {
		return CutoverResult{}, errors.New("native cutover requires stop, release, start and executable seams")
	}
	digest, err := verifyCutoverCandidate(ctx, req.Candidate, req.ConfirmedDigest)
	if err != nil {
		return CutoverResult{}, err
	}
	current, err := seams.currentExecutable()
	if err != nil {
		return CutoverResult{}, err
	}
	if sameFile(current, req.Candidate) {
		return CutoverResult{}, errors.New("native cutover candidate is the running executable")
	}
	// The compatible stop below needs the retention from before this
	// cutover, so the running owner drains before anything is retained.
	if err := cutoverStop(ctx, req.State, req.Dir, seams); err != nil {
		return CutoverResult{}, err
	}
	if err := seams.waitReleased(ctx, req.State); err != nil {
		return CutoverResult{}, err
	}
	retained, retainedDigest, err := retainCutoverPrevious(req.State, current)
	if err != nil {
		return CutoverResult{}, err
	}
	if err := writeCutoverLedger(req.State, cutoverLedger{
		Previous:        retained,
		PreviousDigest:  retainedDigest,
		Candidate:       req.Candidate,
		CandidateDigest: digest,
	}); err != nil {
		return CutoverResult{}, err
	}
	if err := seams.start(ctx, req.State, req.Dir, req.Candidate); err != nil {
		if backErr := seams.start(ctx, req.State, req.Dir, retained); backErr != nil {
			return CutoverResult{}, errors.Join(
				fmt.Errorf("native cutover candidate failed to boot: %w", err),
				fmt.Errorf("the retained previous binary failed to boot: %w", backErr),
				errors.New(manualOwnerStop(req.State)),
			)
		}
		return CutoverResult{Previous: retained, Digest: digest},
			fmt.Errorf("native cutover candidate failed to boot: %w; fell back to the previous binary", err)
	}
	return CutoverResult{Previous: retained, Digest: digest}, nil
}

// runCutoverRollback stops the current owner and boots the binary the
// cutover ledger retained, after re-verifying its digest.
func runCutoverRollback(ctx context.Context, state, dir string, seams cutoverSeams) error {
	if ctx == nil {
		return errors.New("native rollback requires a context")
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if !filepath.IsAbs(state) || !filepath.IsAbs(dir) {
		return errors.New("native rollback requires absolute state and project directories")
	}
	if seams.stopOld == nil || seams.waitReleased == nil || seams.start == nil {
		return errors.New("native rollback requires stop, release and start seams")
	}
	ledger, err := readCutoverLedger(state)
	if err != nil {
		return err
	}
	digest, err := sha256File(ledger.Previous)
	if err != nil {
		return err
	}
	if digest != ledger.PreviousDigest {
		return errors.New("the retained previous binary does not match the cutover ledger")
	}
	if err := cutoverStop(ctx, state, dir, seams); err != nil {
		return err
	}
	if err := seams.waitReleased(ctx, state); err != nil {
		return err
	}
	if err := seams.start(ctx, state, dir, ledger.Previous); err != nil {
		return errors.Join(
			fmt.Errorf("native rollback failed to boot the previous binary: %w", err),
			errors.New(manualOwnerStop(state)),
		)
	}
	return nil
}

// cutoverStop drains the running owner over the authenticated client
// channel. When this binary cannot speak to an older owner it issues the
// stop through the retained previous binary instead, and surfaces the manual
// termination guidance only when that route also fails.
func cutoverStop(ctx context.Context, state, dir string, seams cutoverSeams) error {
	if err := seams.stopOld(ctx, state, dir); err == nil {
		return nil
	} else if !errors.Is(err, errOlderOwnerProtocol) {
		return err
	} else {
		ledger, ledgerErr := readCutoverLedger(state)
		if ledgerErr != nil {
			return errors.Join(err, ledgerErr, errors.New(manualOwnerStop(state)))
		}
		if seams.stopOldCompatible == nil {
			return errors.Join(err, errors.New(manualOwnerStop(state)))
		}
		if stopErr := seams.stopOldCompatible(ctx, state, ledger.Previous); stopErr != nil {
			return errors.Join(err, stopErr, errors.New(manualOwnerStop(state)))
		}
		return nil
	}
}

// verifyCutoverCandidate checks the candidate against the person-confirmed
// exact digest and runs its readiness self-test. It returns the verified
// digest.
func verifyCutoverCandidate(ctx context.Context, candidate, confirmed string) (string, error) {
	decoded, err := hex.DecodeString(strings.TrimSpace(confirmed))
	if err != nil || len(decoded) != sha256.Size || hex.EncodeToString(decoded) != strings.TrimSpace(confirmed) {
		return "", errors.New("native cutover needs the person-confirmed candidate digest as 64 lowercase hexadecimal characters")
	}
	info, err := os.Stat(candidate)
	if err != nil {
		return "", fmt.Errorf("native cutover candidate: %w", err)
	}
	if !info.Mode().IsRegular() {
		return "", errors.New("native cutover candidate is not a regular file")
	}
	digest, err := sha256File(candidate)
	if err != nil {
		return "", err
	}
	if digest != strings.TrimSpace(confirmed) {
		return "", errors.New("native cutover candidate digest does not match the person-confirmed digest")
	}
	self, cancel := context.WithTimeout(ctx, cutoverSelfTestTimeout)
	defer cancel()
	command := exec.CommandContext(self, candidate, "help")
	output, err := command.Output()
	if err != nil {
		return "", fmt.Errorf("native cutover candidate self-test failed: %w", err)
	}
	if len(strings.TrimSpace(string(output))) == 0 {
		return "", errors.New("native cutover candidate self-test printed no help")
	}
	return digest, nil
}

// sha256File hashes a file without loading it into memory.
func sha256File(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer func() { _ = file.Close() }()
	sum := sha256.New()
	if _, err := io.Copy(sum, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(sum.Sum(nil)), nil
}

// retainCutoverPrevious copies the running helper binary into the
// owner-owned state directory as the one-step rollback binary.
func retainCutoverPrevious(state, current string) (string, string, error) {
	resolved, err := filepath.EvalSymlinks(current)
	if err != nil {
		resolved = current
	}
	digest, err := sha256File(resolved)
	if err != nil {
		return "", "", err
	}
	directory := ownerDirectory(state)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return "", "", err
	}
	previous := filepath.Join(directory, cutoverPreviousName)
	source, err := os.Open(resolved)
	if err != nil {
		return "", "", err
	}
	defer func() { _ = source.Close() }()
	staged, err := os.CreateTemp(directory, "."+cutoverPreviousName+".*")
	if err != nil {
		return "", "", err
	}
	stagedName := staged.Name()
	defer func() {
		if err != nil {
			_ = os.Remove(stagedName)
		}
	}()
	if _, err = io.Copy(staged, source); err != nil {
		_ = staged.Close()
		return "", "", err
	}
	if err = staged.Chmod(0o700); err != nil {
		_ = staged.Close()
		return "", "", err
	}
	if err = staged.Sync(); err != nil {
		_ = staged.Close()
		return "", "", err
	}
	if err = staged.Close(); err != nil {
		return "", "", err
	}
	if err = os.Rename(stagedName, previous); err != nil {
		return "", "", err
	}
	return previous, digest, nil
}

// cutoverLedger is the versioned record of the last cutover.
type cutoverLedger struct {
	Version         int    `json:"version"`
	Previous        string `json:"previous"`
	PreviousDigest  string `json:"previous_digest"`
	Candidate       string `json:"candidate"`
	CandidateDigest string `json:"candidate_digest"`
}

func cutoverLedgerPath(state string) string {
	return filepath.Join(ownerDirectory(state), cutoverLedgerName)
}

func writeCutoverLedger(state string, ledger cutoverLedger) error {
	ledger.Version = 1
	data, err := json.Marshal(ledger)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(ownerDirectory(state), 0o700); err != nil {
		return err
	}
	return writeOwnerFile(cutoverLedgerPath(state), append(data, '\n'))
}

func readCutoverLedger(state string) (cutoverLedger, error) {
	var ledger cutoverLedger
	data, err := os.ReadFile(cutoverLedgerPath(state))
	if errors.Is(err, os.ErrNotExist) {
		return cutoverLedger{}, errors.New("no native cutover was recorded for this state; no previous binary is retained")
	}
	if err != nil {
		return cutoverLedger{}, err
	}
	decoder := json.NewDecoder(strings.NewReader(strings.TrimSpace(string(data))))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&ledger); err != nil {
		return cutoverLedger{}, errors.New("the native cutover ledger is invalid")
	}
	if ledger.Version != 1 || ledger.Previous == "" || ledger.PreviousDigest == "" {
		return cutoverLedger{}, errors.New("the native cutover ledger is invalid")
	}
	return ledger, nil
}

func sameFile(first, second string) bool {
	if first == "" || second == "" {
		return false
	}
	return filepath.Clean(first) == filepath.Clean(second)
}
