// SPDX-License-Identifier: MIT

package hive

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"strings"

	"github.com/wippyai/bee/native/hive/invite"
)

// oneWayNotice explains a machine only the other side can be dialed from: the
// mesh carries gossip and calls over the connections the dialing side opens, so
// the hive works; a machine others can dial directly also accepts connections.
const oneWayNotice = "The hive works over the connections this machine opens. To let the other machine dial this one as well, put both on a shared network or Tailscale, or under WSL2 enable mirrored networking.\n"

// Join redeems the invite token for this machine. The hive is created when the
// machine has none, and its secret is replaced by the hive's, so the machine's
// nodes join the hive the invite names when they start.
func Join(ctx context.Context, dir, token string, out io.Writer) error {
	line, err := invite.Parse(token)
	if err != nil {
		return fmt.Errorf("bee hive join: %w", err)
	}
	hive, err := Ensure(dir)
	if err != nil {
		return err
	}
	assigned, err := assignedInterfaceAddresses()
	if err != nil {
		return fmt.Errorf("bee hive join: inspect network interfaces: %w", err)
	}
	addresses := make([]string, 0, maxProbeAddresses)
	for _, item := range assigned {
		if len(addresses) < maxProbeAddresses {
			addresses = append(addresses, item.address.String())
		}
	}
	_, identity, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	probe, err := net.Listen("tcp", ":0")
	if err != nil {
		return fmt.Errorf("bee hive join: listen: %w", err)
	}
	probing, stopProbing := context.WithCancel(ctx)
	defer stopProbing()
	go func() { _ = invite.ServeProbe(probing, probe, identity) }()
	request := invite.Request{Node: hive.Machine, Addresses: addresses, ProbePort: probe.Addr().(*net.TCPAddr).Port, Port: hive.Port}
	admission, _, path, err := invite.DialCandidates(ctx, line, identity, request)
	if err != nil {
		var refused *invite.Refused
		if errors.As(err, &refused) {
			return fmt.Errorf("bee hive join: %w", err)
		}
		return fmt.Errorf("bee hive join: %w\n%s", err, joinFailureAdvice(line))
	}
	secret, err := base64.StdEncoding.DecodeString(admission.Secret)
	if err != nil || len(secret) != 32 {
		return errors.New("bee hive join: the hive node sent an invalid hive secret")
	}
	advertise, _ := netip.ParseAddr(admission.Reached)
	verified := advertise.IsValid()
	if !verified {
		if advertise, err = routeSource(path.Endpoint); err != nil {
			return fmt.Errorf("bee hive join: find this machine's address towards %s: %w", path.Endpoint, err)
		}
	}
	seeds := make([]string, 0, len(admission.Seeds))
	for _, seed := range admission.Seeds {
		if _, err := netip.ParseAddrPort(seed); err == nil {
			seeds = appendUnique(seeds, seed)
		}
	}
	hive.Secret = admission.Secret
	hive.Advertise = advertise.String()
	hive.Seeds = seeds
	if err := WriteHive(dir, *hive); err != nil {
		return err
	}
	fmt.Fprintf(out, "Joined the hive of machine %s through %s.\nThis machine is %s at %s.\n", admission.Node, path.Endpoint, hive.Machine, hive.Advertise)
	if !verified {
		fmt.Fprintf(out, "The other machine cannot dial %s back.\n%s", hive.Advertise, oneWayNotice)
		if guest, ok := wslNATGuest(assigned); ok {
			fmt.Fprintf(out, "This machine is a WSL2 guest behind the Windows NAT (%s). To %s.\n", guest, mirroredNetworking)
		}
	}
	fmt.Fprint(out, "The token is no longer needed: this machine stays in the hive.\n", restartNotice)
	return nil
}

// routeSource returns the local address this machine uses to reach endpoint.
func routeSource(endpoint string) (netip.Addr, error) {
	connection, err := net.Dial("udp", endpoint)
	if err != nil {
		return netip.Addr{}, err
	}
	defer connection.Close()
	host, _, err := net.SplitHostPort(connection.LocalAddr().String())
	if err != nil {
		return netip.Addr{}, err
	}
	address, err := netip.ParseAddr(strings.TrimSpace(host))
	if err != nil {
		return netip.Addr{}, err
	}
	return address.Unmap(), nil
}
