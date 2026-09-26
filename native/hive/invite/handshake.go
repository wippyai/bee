// SPDX-License-Identifier: MIT

package invite

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/netip"
	"sync"
	"time"
)

const (
	// Version is the handshake revision both messages carry.
	Version = 1
	// MaxMessageBytes bounds each handshake message.
	MaxMessageBytes = 64 * 1024
	// Timeout bounds one whole handshake on either side.
	Timeout = 15 * time.Second
	// decisionTimeout bounds the handler, so its answer is written within the
	// connection's deadline.
	decisionTimeout = 10 * time.Second
	// maxConcurrent bounds the handshakes a listener serves at once.
	maxConcurrent = 8
)

// Request is the joiner's only message. Secret is the invite secret, which
// the joiner sends only after it has pinned the hive node's identity key.
type Request struct {
	Version   int      `json:"version"`
	Invite    string   `json:"invite"`
	Secret    string   `json:"secret"`
	Node      string   `json:"node"`
	Addresses []string `json:"addresses"`
	// Key is the base64 public key the hive node certifies for the joiner's
	// mesh credential; it is separate from the joiner's identity key.
	Key string `json:"tls_key"`
	// Observed is the IP the hive node saw on this authenticated TCP
	// connection. The listener writes it from the accepted socket before the
	// handler runs; a value arriving on the wire is overwritten and is never
	// trusted.
	Observed string `json:"observed,omitempty"`
}

// Admission is what the hive node returns to an admitted joiner: its node, the
// gossip seed, the mesh secret, the joiner's certified mesh leaf and the pool
// of authorities the hive trusts.
type Admission struct {
	Version     int    `json:"version"`
	Node        string `json:"node"`
	Gossip      string `json:"gossip"`
	Secret      string `json:"secret"`
	Certificate string `json:"certificate"`
	Authorities string `json:"authorities"`
	// Observed is the IP the hive node saw the joiner connect from. The joiner
	// uses it to learn its own reachable address when that IP is assigned
	// locally, and to mark itself NATed when it is not.
	Observed string `json:"observed,omitempty"`
}

// Refused is a definite refusal by the hive node.
type Refused struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (r *Refused) Error() string { return "invite refused: " + r.Code + ": " + r.Message }

type response struct {
	Admission *Admission `json:"admission,omitempty"`
	Refused   *Refused   `json:"refused,omitempty"`
}

// Handler admits or refuses one joiner. peer is the identity key the joiner
// proved with its client certificate.
type Handler func(ctx context.Context, peer ed25519.PublicKey, request Request) (Admission, *Refused)

// certificate is a self-signed TLS certificate carrying the identity key.
// Only the key matters: each side pins or records it, never the name or chain.
func certificate(identity ed25519.PrivateKey) (tls.Certificate, error) {
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "Bee Hive join"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		KeyUsage:    x509.KeyUsageDigitalSignature,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth, x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, template, template, identity.Public(), identity)
	if err != nil {
		return tls.Certificate{}, err
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: identity}, nil
}

// peerKey returns the identity key of the connection's single peer certificate.
func peerKey(raw [][]byte) (ed25519.PublicKey, error) {
	if len(raw) != 1 {
		return nil, errors.New("invite handshake requires exactly one peer certificate")
	}
	parsed, err := x509.ParseCertificate(raw[0])
	if err != nil {
		return nil, err
	}
	key, ok := parsed.PublicKey.(ed25519.PublicKey)
	if !ok {
		return nil, errors.New("invite handshake requires an Ed25519 identity")
	}
	return key, nil
}

func readMessage(connection net.Conn, into any) error {
	reader := bufio.NewReader(io.LimitReader(connection, MaxMessageBytes+1))
	line, err := reader.ReadBytes('\n')
	if err != nil {
		return err
	}
	if len(line) > MaxMessageBytes {
		return errors.New("invite handshake message exceeds its bound")
	}
	decoder := json.NewDecoder(bytes.NewReader(line))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(into); err != nil {
		return err
	}
	return nil
}

func writeMessage(connection net.Conn, value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	if len(data) > MaxMessageBytes {
		return errors.New("invite handshake message exceeds its bound")
	}
	_, err = connection.Write(append(data, '\n'))
	return err
}

// Dial redeems invite as identity, trying every bounded candidate. It pins the
// hive node's identity key before sending the secret and returns its admission
// with that pinned key, or its definite refusal.
func Dial(ctx context.Context, invite Invite, identity ed25519.PrivateKey, request Request) (Admission, ed25519.PublicKey, error) {
	admission, pinned, _, err := DialCandidates(ctx, invite, identity, request)
	return admission, pinned, err
}

type dialResult struct {
	candidate  Candidate
	connection net.Conn
	pinned     ed25519.PublicKey
	err        error
}

// DialCandidates races all bounded endpoints. Only the first TLS-verified
// connection receives the single-use secret; an uncertain redemption is never
// blindly replayed on another endpoint.
func DialCandidates(ctx context.Context, line Invite, identity ed25519.PrivateKey, request Request) (Admission, ed25519.PublicKey, Candidate, error) {
	if ctx == nil || !line.valid() || len(identity) != ed25519.PrivateKeySize {
		return Admission{}, nil, Candidate{}, ErrInvite
	}
	own, err := certificate(identity)
	if err != nil {
		return Admission{}, nil, Candidate{}, err
	}
	ctx, cancel := context.WithTimeout(ctx, Timeout)
	defer cancel()
	racing, stopRace := context.WithCancel(ctx)
	defer stopRace()
	candidates := append([]Candidate{{Kind: "explicit", Scope: "host", Endpoint: line.Address.String()}}, line.Candidates...)
	results := make(chan dialResult, len(candidates))
	for _, candidate := range candidates {
		go func(candidate Candidate) {
			var pinned ed25519.PublicKey
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
					if Fingerprint(key) != line.Fingerprint {
						return errors.New("hive node identity does not match the invite")
					}
					pinned = key
					return nil
				},
			}
			connection, err := (&tls.Dialer{Config: config}).DialContext(racing, "tcp", candidate.Endpoint)
			result := dialResult{candidate: candidate, connection: connection, pinned: pinned, err: err}
			if racing.Err() != nil && connection != nil {
				_ = connection.Close()
			}
			results <- result
		}(candidate)
	}
	var failures []error
	var selected dialResult
	received := 0
	for range candidates {
		result := <-results
		received++
		if result.err != nil {
			failures = append(failures, fmt.Errorf("%s (%s/%s): %w", result.candidate.Endpoint, result.candidate.Kind, result.candidate.Scope, result.err))
			continue
		}
		selected = result
		break
	}
	if selected.connection == nil {
		return Admission{}, nil, Candidate{}, fmt.Errorf("join failed; candidates tried: %w", errors.Join(failures...))
	}
	stopRace()
	go func() {
		for i := received; i < len(candidates); i++ {
			if result := <-results; result.connection != nil {
				_ = result.connection.Close()
			}
		}
	}()
	connection := selected.connection
	defer connection.Close()
	// The peer's socket address is the route actually authenticated. In
	// particular a MagicDNS name may resolve to one of several tailnet IPs.
	selected.candidate.Endpoint = connection.RemoteAddr().String()
	if deadline, ok := ctx.Deadline(); ok {
		_ = connection.SetDeadline(deadline)
	}
	request.Version = Version
	request.Invite = line.ID
	request.Secret = line.Secret
	if err := writeMessage(connection, request); err != nil {
		return Admission{}, nil, Candidate{}, err
	}
	var reply response
	if err := readMessage(connection, &reply); err != nil {
		return Admission{}, nil, Candidate{}, fmt.Errorf("join %s: %w", selected.candidate.Endpoint, err)
	}
	switch {
	case reply.Refused != nil && reply.Admission == nil:
		return Admission{}, nil, Candidate{}, reply.Refused
	case reply.Admission != nil && reply.Refused == nil && reply.Admission.Version == Version && reply.Admission.Node == line.Node &&
		validObserved(reply.Admission.Observed):
		return *reply.Admission, selected.pinned, selected.candidate, nil
	default:
		return Admission{}, nil, Candidate{}, errors.New("hive node sent an invalid admission")
	}
}

// validObserved accepts an absent observed address, or a bare IP literal the
// hive node reported.
func validObserved(value string) bool {
	if value == "" {
		return true
	}
	address, err := netip.ParseAddr(value)
	return err == nil && address.Zone() == "" && !address.IsUnspecified()
}

// Serve accepts joiners on listener as identity until ctx ends. Each
// connection gets one bounded handshake; handler decides it.
func Serve(ctx context.Context, listener net.Listener, identity ed25519.PrivateKey, handler Handler) error {
	if ctx == nil || listener == nil || len(identity) != ed25519.PrivateKeySize || handler == nil {
		return errors.New("invalid invite listener")
	}
	own, err := certificate(identity)
	if err != nil {
		return err
	}
	config := &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{own}, ClientAuth: tls.RequireAnyClientCert}
	stop := context.AfterFunc(ctx, func() { _ = listener.Close() })
	defer stop()
	slots := make(chan struct{}, maxConcurrent)
	var active sync.WaitGroup
	defer active.Wait()
	for {
		connection, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		select {
		case slots <- struct{}{}:
		default:
			_ = connection.Close()
			continue
		}
		active.Add(1)
		go func() {
			defer active.Done()
			defer func() { <-slots }()
			serve(ctx, tls.Server(connection, config), handler)
		}()
	}
}

func serve(ctx context.Context, connection *tls.Conn, handler Handler) {
	defer connection.Close()
	ctx, cancel := context.WithTimeout(ctx, Timeout)
	defer cancel()
	deadline, _ := ctx.Deadline()
	_ = connection.SetDeadline(deadline)
	if err := connection.HandshakeContext(ctx); err != nil {
		return
	}
	state := connection.ConnectionState()
	raw := make([][]byte, 0, len(state.PeerCertificates))
	for _, certificate := range state.PeerCertificates {
		raw = append(raw, certificate.Raw)
	}
	peer, err := peerKey(raw)
	if err != nil {
		return
	}
	var request Request
	if err := readMessage(connection, &request); err != nil {
		return
	}
	// The accepted socket is the only trustworthy statement of where this
	// joiner connects from, so the listener replaces whatever the wire said.
	request.Observed = ""
	if host, _, err := net.SplitHostPort(connection.RemoteAddr().String()); err == nil {
		request.Observed = host
	}
	if request.Version != Version {
		_ = writeMessage(connection, response{Refused: &Refused{Code: "UNSUPPORTED_SCHEMA", Message: "unsupported invite handshake version"}})
		return
	}
	decision, cancelDecision := context.WithTimeout(ctx, decisionTimeout)
	defer cancelDecision()
	admission, refused := handler(decision, peer, request)
	if refused != nil {
		_ = writeMessage(connection, response{Refused: refused})
		return
	}
	admission.Version = Version
	// The listener owns the observed address: whatever the handler said is
	// replaced with what the accepted socket actually showed.
	admission.Observed = request.Observed
	_ = writeMessage(connection, response{Admission: &admission})
}
