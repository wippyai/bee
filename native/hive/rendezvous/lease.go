// SPDX-License-Identifier: MIT

package rendezvous

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/wippyai/bee/native/internal/privatefile"
)

// PeerLease holds one local process slot. Its OS lock, rather than an age or
// claimed PID, prevents a live client from being reclaimed. Close follows native
// transport shutdown. Abrupt process death releases the lock in the OS.
type PeerLease struct {
	enrollment *Enrollment
	execution  string
	node       string
	key        ed25519.PublicKey
	slot       int
	unlock     func() error
	once       sync.Once
	err        error
}

// RegisterHeld admits a client while retaining a bounded process slot. It may
// reclaim only the record assigned to the slot whose OS lock it acquired. Raw
// Register entries and other live slots are never evicted. It is not a desktop
// grant and does not revoke already established application sessions.
func (e *Enrollment) RegisterHeld(ctx context.Context, execution, node string, key ed25519.PublicKey) (*PeerLease, Snapshot, error) {
	if ctx == nil || !validExecution(execution) || !validPeer(node) || len(key) != ed25519.PublicKeySize {
		return nil, Snapshot{}, ErrEnrollment
	}
	// Do not create any slot files for missing, malformed or replaced enrollment.
	current, err := e.Read(ctx, execution)
	if err != nil {
		return nil, Snapshot{}, err
	}
	slots := make([]int, 0, MaxLocalPeers)
	previousSlot, sameNode := current.slots[node]
	if sameNode {
		slots = append(slots, previousSlot)
	} else {
		for slot := 0; slot < MaxLocalPeers; slot++ {
			slots = append(slots, slot)
		}
	}
	var lease *PeerLease
	for _, slot := range slots {
		unlock, err := privatefile.TryLock(ctx, e.directory, fmt.Sprintf(".client-slot-%03d.lock", slot))
		if errors.Is(err, privatefile.ErrLockBusy) {
			if sameNode {
				return nil, Snapshot{}, ErrPeerConflict
			}
			continue
		}
		if err != nil {
			return nil, Snapshot{}, err
		}
		lease = &PeerLease{enrollment: e, execution: execution, node: node, key: bytes.Clone(key), slot: slot, unlock: unlock}
		break
	}
	if lease == nil {
		return nil, Snapshot{}, ErrPeerCapacity
	}
	encoded := base64.RawStdEncoding.EncodeToString(key)
	var result Snapshot
	err = e.file.ReadModifyWrite(ctx, maxEnrollmentBytes, func(data []byte) ([]byte, error) {
		record, err := decodeEnrollment(data)
		if err != nil {
			return nil, err
		}
		if record.Execution != execution {
			return nil, ErrOwnerChanged
		}
		// The held lock proves that this slot has no live native holder. The
		// slot index is validated and unique by decodeEnrollment.
		for previous, slot := range record.Slots {
			if slot == lease.slot {
				delete(record.Peers, previous)
				delete(record.Slots, previous)
				break
			}
		}
		if _, exists := record.Peers[node]; exists {
			return nil, ErrPeerConflict
		}
		if len(record.Peers) >= MaxLocalPeers {
			return nil, ErrPeerCapacity
		}
		record.Peers[node] = encoded
		record.Slots[node] = lease.slot
		result = snapshot(record)
		return json.Marshal(record)
	})
	if err != nil {
		// Publication may have committed before reporting a durability error.
		// Exact-slot cleanup is safe on that path and cannot remove another lease.
		cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), 3*time.Second)
		defer cancel()
		return nil, Snapshot{}, errors.Join(err, lease.Close(cleanup))
	}
	return lease, result, nil
}

// Close removes only the exact slot/execution/node/key record, then releases the
// stable OS lock even if storage cleanup failed. A future holder can reclaim a
// leftover row. Never unlink slot lock files: there are at most MaxLocalPeers.
func (l *PeerLease) Close(ctx context.Context) error {
	if ctx == nil {
		return ErrEnrollment
	}
	l.once.Do(func() {
		l.err = l.enrollment.file.ReadModifyWrite(ctx, maxEnrollmentBytes, func(data []byte) ([]byte, error) {
			record, err := decodeEnrollment(data)
			if err != nil {
				return nil, err
			}
			if record.Execution != l.execution {
				return nil, ErrOwnerChanged
			}
			encoded, exists := record.Peers[l.node]
			if !exists {
				return nil, nil
			}
			slot, managed := record.Slots[l.node]
			if !managed || slot != l.slot || encoded != base64.RawStdEncoding.EncodeToString(l.key) {
				return nil, ErrPeerConflict
			}
			delete(record.Peers, l.node)
			delete(record.Slots, l.node)
			return json.Marshal(record)
		})
		l.err = errors.Join(l.err, l.unlock())
	})
	return l.err
}
