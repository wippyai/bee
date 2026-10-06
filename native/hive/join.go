// SPDX-License-Identifier: MIT

package hive

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"os/signal"
	"strconv"
	"sync"
	"time"

	"github.com/wippyai/bee/native/hive/invite"
)

// InviteLifetime is how long an invite stays redeemable.
const InviteLifetime = 10 * time.Minute

// joinPort is the TCP port `bee hive invite` listens on when it is free.
const joinPort = 47931

// maxProbeAddresses bounds the joiner addresses an invite probes.
const maxProbeAddresses = 16

// Invite creates the hive when this machine has none, prints an invite for
// another machine and serves it until it is redeemed, expires or ctx ends.
// The invite line goes to out; guidance goes to notes.
func Invite(ctx context.Context, dir string, out, notes io.Writer) error {
	hive, err := Ensure(dir)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(ctx, os.Interrupt)
	defer stop()
	listener, err := net.Listen("tcp", net.JoinHostPort("", strconv.Itoa(joinPort)))
	if err != nil {
		if listener, err = net.Listen("tcp", ":0"); err != nil {
			return fmt.Errorf("bee hive invite: listen: %w", err)
		}
	}
	defer listener.Close()
	port := uint16(listener.Addr().(*net.TCPAddr).Port)
	assigned, err := assignedInterfaceAddresses()
	if err != nil {
		return fmt.Errorf("bee hive invite: inspect network interfaces: %w", err)
	}
	tailnet, magicDNS := tailscaleIdentity()
	candidates := selectJoinCandidates(port, assigned, tailnet, magicDNS)
	primary := netip.AddrPortFrom(netip.MustParseAddr("127.0.0.1"), port)
	for index, candidate := range candidates {
		if address, err := netip.ParseAddrPort(candidate.Endpoint); err == nil {
			primary = address
			candidates = append(candidates[:index:index], candidates[index+1:]...)
			break
		}
	}
	_, identity, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	id, secret := randomHex(16), randomHex(32)
	line := invite.Invite{ID: id, Secret: secret, Address: primary, Node: hive.Machine,
		Fingerprint: invite.Fingerprint(identity.Public().(ed25519.PublicKey)), Candidates: candidates}
	if len(candidates) > invite.MaxCandidates {
		line.Candidates = candidates[:invite.MaxCandidates]
	}
	session := &inviteSession{dir: dir, id: id, digest: sha256.Sum256([]byte(secret)), identity: identity, expires: time.Now().Add(InviteLifetime), notes: notes}
	if _, err := fmt.Fprintln(out, line.String()); err != nil {
		return err
	}
	fmt.Fprintf(notes, "Valid for %d minutes, single use. On the other machine run:\n  bee hive join TOKEN\nwith the line above as TOKEN. Keep this command running until it joins.\n",
		int(InviteLifetime/time.Minute))
	if notice := inviteNotice(line.Candidates, assigned); notice != "" {
		fmt.Fprint(notes, notice)
	}
	serving, cancel := context.WithDeadline(ctx, session.expires)
	defer cancel()
	session.finished = cancel
	if err := invite.Serve(serving, listener, identity, session.handle); err != nil {
		return err
	}
	switch {
	case session.joined != "":
		fmt.Fprintf(notes, "Machine %s joined the hive.\n%s", session.joined, restartNotice)
		return nil
	case ctx.Err() != nil:
		return errors.New("bee hive invite: cancelled; the invite is no longer valid")
	default:
		return errors.New("bee hive invite: the invite expired unused")
	}
}

const restartNotice = "Bees already running on this machine keep their old network settings; restart them to be reachable from the other machine.\n"

type inviteSession struct {
	dir      string
	id       string
	digest   [sha256.Size]byte
	expires  time.Time
	notes    io.Writer
	identity ed25519.PrivateKey
	finished context.CancelFunc

	mu     sync.Mutex
	joined string
}

func refuse(code, message string) invite.Decision {
	return invite.Reject(invite.Refused{Code: code, Message: message})
}

// handle redeems the invite for one authenticated joiner. It runs under the
// session lock, so one joiner redeems the single-use invite.
func (s *inviteSession) handle(ctx context.Context, peer ed25519.PublicKey, request invite.Request) invite.Decision {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.joined != "" {
		return refuse("CONFLICT", "invite was already used")
	}
	given := sha256.Sum256([]byte(request.Secret))
	if request.Invite != s.id || subtle.ConstantTimeCompare(given[:], s.digest[:]) != 1 {
		return refuse("DENIED", "invite secret does not match")
	}
	if time.Now().After(s.expires) {
		return refuse("EXPIRED", "invite expired")
	}
	hive, err := Ensure(s.dir)
	if err != nil {
		return refuse("UNAVAILABLE", err.Error())
	}
	if !invite.ValidNode(request.Node) || request.Node == hive.Machine {
		return refuse("DENIED", "a machine cannot join its own hive")
	}
	if request.Port <= 0 || request.Port > 65535 || request.ProbePort <= 0 || request.ProbePort > 65535 || len(request.Addresses) > maxProbeAddresses {
		return refuse("DENIED", "invalid join request")
	}
	local, err := netip.ParseAddr(request.Local)
	if err != nil {
		return refuse("UNAVAILABLE", "join path has no local address")
	}
	local = local.Unmap()
	reached, reachErr := invite.Reach(ctx, request.Addresses, request.ProbePort, peer, s.identity)
	seeds := []string{net.JoinHostPort(local.String(), strconv.Itoa(hive.Port))}
	seeds = append(seeds, hive.Seeds...)
	if hive.Advertise == "" {
		hive.Advertise = local.String()
	}
	if reachErr == nil {
		hive.Seeds = appendUnique(hive.Seeds, net.JoinHostPort(reached.String(), strconv.Itoa(request.Port)))
	} else {
		fmt.Fprintf(s.notes, "This machine cannot reach %s (%v); its bees can dial this machine but not the other way round.\n%s",
			request.Observed, reachErr, unreachableAdvice)
	}
	if err := WriteHive(s.dir, *hive); err != nil {
		return refuse("UNAVAILABLE", err.Error())
	}
	s.joined = request.Node
	s.finished()
	return invite.Accept(invite.Admission{Node: hive.Machine, Secret: hive.Secret, Seeds: seeds})
}
