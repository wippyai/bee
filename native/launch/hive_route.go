//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"os"
	"time"

	"github.com/wippyai/bee/native/client/hive"
	"github.com/wippyai/bee/native/hive/invite"
	"github.com/wippyai/bee/native/hive/rendezvous"
)

// awaitSessionTimeout bounds how long a join waits for its first session.
const awaitSessionTimeout = 60 * time.Second

// runHive performs one `bee hive` command against the owner's supervisor.
func runHive(ctx context.Context, out io.Writer, client *hive.Join, directory string, command hiveCommand) error {
	switch command.verb {
	case hiveInvite:
		minted, err := client.Invite(ctx)
		if err != nil {
			return err
		}
		// The owner publishes its join listener at startup; the invite carries
		// that listener, the owner's node and its identity key fingerprint.
		owner, err := readDescriptor(ctx, directory)
		if err != nil {
			return err
		}
		address, err := netip.ParseAddrPort(owner.Join)
		if err != nil {
			return errors.New("this Bee has no join listener")
		}
		key, err := base64.RawStdEncoding.DecodeString(owner.PublicKey)
		if err != nil || len(key) != ed25519.PublicKeySize {
			return rendezvous.ErrDescriptor
		}
		line := invite.Invite{ID: minted.ID, Secret: minted.Secret, Address: address, Node: owner.Node, Fingerprint: invite.Fingerprint(key)}
		if _, err := fmt.Fprintln(out, line.String()); err != nil {
			return err
		}
		_, err = io.WriteString(os.Stderr, inviteHint(line.String()))
		return err
	case hiveInvites:
		records, err := client.Invites(ctx)
		if err != nil {
			return err
		}
		if _, err := fmt.Fprintln(out, "INVITE                            STATUS   EXPIRES                   NODE"); err != nil {
			return err
		}
		for _, record := range records {
			if _, err := fmt.Fprintf(out, "%s  %-7s  %s  %s\n", record.ID, record.Status, record.ExpiresAt, record.Node); err != nil {
				return err
			}
		}
		return nil
	case hiveRevoke:
		record, err := client.Revoke(ctx, command.id)
		if err != nil {
			return err
		}
		_, err = fmt.Fprintf(out, "Invite %s %s\n", record.ID, record.Status)
		return err
	case hivePeers:
		view, err := client.Peers(ctx)
		if err != nil {
			return err
		}
		if _, err := fmt.Fprintf(out, "NODE %s\nPEER                                SESSION\n", view.Node); err != nil {
			return err
		}
		for _, peer := range view.Peers {
			if _, err := fmt.Fprintf(out, "%-34s  %s\n", peer.Node, peer.Session); err != nil {
				return err
			}
		}
		return nil
	case hiveAwait:
		return awaitSession(ctx, out, client, command.node)
	}
	return fmt.Errorf("bee hive %s is not an owner operation", command.verb)
}

// awaitSession waits until the owner holds an established supervisor session
// with the hive node it joined.
func awaitSession(ctx context.Context, out io.Writer, client *hive.Join, node string) error {
	ctx, cancel := context.WithTimeout(ctx, awaitSessionTimeout)
	defer cancel()
	tick := time.NewTicker(250 * time.Millisecond)
	defer tick.Stop()
	for {
		view, err := client.Peers(ctx)
		if err != nil {
			return err
		}
		for _, peer := range view.Peers {
			if peer.Node == node && peer.Session == "established" {
				_, err := fmt.Fprintf(out, "Joined the hive of %s as %s\n", node, view.Node)
				return err
			}
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("joined the hive of %s, but no session was established: %w", node, ctx.Err())
		case <-tick.C:
		}
	}
}
