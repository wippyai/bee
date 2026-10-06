// SPDX-License-Identifier: MIT

package invite

import (
	"context"
	"crypto/ed25519"
	"crypto/tls"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"strconv"
	"time"
)

// ProbeTimeout bounds one reachability probe.
const ProbeTimeout = 4 * time.Second

// Reach dials the joiner's probe listener on every address concurrently and
// returns the first address whose listener proves the joiner's identity key.
// The listener on the other end proves the hive node's identity key in turn, so
// only the two parties of the invite complete a probe.
func Reach(ctx context.Context, addresses []string, port int, joiner ed25519.PublicKey, identity ed25519.PrivateKey) (netip.Addr, error) {
	if len(addresses) == 0 || port <= 0 || port > 65535 {
		return netip.Addr{}, errors.New("no probe address")
	}
	own, err := certificate(identity)
	if err != nil {
		return netip.Addr{}, err
	}
	ctx, cancel := context.WithTimeout(ctx, ProbeTimeout)
	defer cancel()
	type result struct {
		address netip.Addr
		err     error
	}
	results := make(chan result, len(addresses))
	for _, value := range addresses {
		go func(value string) {
			address, err := netip.ParseAddr(value)
			if err != nil || address.Zone() != "" || address.IsUnspecified() {
				results <- result{err: fmt.Errorf("%s: not an address", value)}
				return
			}
			config := &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{own}, InsecureSkipVerify: true,
				VerifyConnection: func(state tls.ConnectionState) error {
					raw := make([][]byte, 0, len(state.PeerCertificates))
					for _, peer := range state.PeerCertificates {
						raw = append(raw, peer.Raw)
					}
					key, err := peerKey(raw)
					if err != nil {
						return err
					}
					if !key.Equal(joiner) {
						return errors.New("probe listener is not the joiner")
					}
					return nil
				}}
			endpoint := net.JoinHostPort(address.String(), strconv.Itoa(port))
			connection, err := (&tls.Dialer{Config: config}).DialContext(ctx, "tcp", endpoint)
			if err != nil {
				results <- result{err: fmt.Errorf("%s: %w", endpoint, err)}
				return
			}
			_ = connection.Close()
			results <- result{address: address}
		}(value)
	}
	var failures []error
	for range addresses {
		r := <-results
		if r.err == nil {
			return r.address, nil
		}
		failures = append(failures, r.err)
	}
	return netip.Addr{}, errors.Join(failures...)
}

// ServeProbe accepts the hive node's reachability probes on listener until ctx
// ends. A probe counts when the connecting peer proves the identity key whose
// fingerprint the invite carries; the local address it reached is sent to
// reached. The joiner learns from it which of its addresses the hive node can
// reach.
func ServeProbe(ctx context.Context, listener net.Listener, identity ed25519.PrivateKey, fingerprint string, reached chan<- netip.Addr) error {
	own, err := certificate(identity)
	if err != nil {
		return err
	}
	config := &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{own}, ClientAuth: tls.RequireAnyClientCert}
	stop := context.AfterFunc(ctx, func() { _ = listener.Close() })
	defer stop()
	for {
		connection, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		go func() {
			defer connection.Close()
			secured := tls.Server(connection, config)
			handshake, cancel := context.WithTimeout(ctx, ProbeTimeout)
			defer cancel()
			if secured.HandshakeContext(handshake) != nil {
				return
			}
			state := secured.ConnectionState()
			raw := make([][]byte, 0, len(state.PeerCertificates))
			for _, peer := range state.PeerCertificates {
				raw = append(raw, peer.Raw)
			}
			key, err := peerKey(raw)
			if err != nil || Fingerprint(key) != fingerprint {
				return
			}
			host, _, err := net.SplitHostPort(connection.LocalAddr().String())
			if err != nil {
				return
			}
			address, err := netip.ParseAddr(host)
			if err != nil {
				return
			}
			select {
			case reached <- address.Unmap():
			default:
			}
		}()
	}
}
