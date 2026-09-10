// SPDX-License-Identifier: MIT

package local

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"

	"github.com/wippyai/bee/native/internal/privatefile"
)

const (
	// DefaultSetupTimeout bounds setup duration even if the caller does not specify a context deadline.
	DefaultSetupTimeout = 5 * time.Second

	// DefaultHandshakeTimeout bounds incoming mutual TLS handshake duration to prevent slowloris starvation.
	DefaultHandshakeTimeout = 5 * time.Second

	// maxPendingHandshakes limits concurrent in-flight handshakes.
	maxPendingHandshakes = 32
)

// Listener owns the local physical-client mutual TLS rendezvous socket and publication state.
// Admitted connections transfer full ownership to the caller upon return from Accept and
// remain open when Listener.Close is invoked.
type Listener struct {
	tcpLn     *net.TCPListener
	tlsConfig *tls.Config
	endpoint  string
	runID     string
	desc      *Descriptor

	accepting atomic.Bool

	mu      sync.Mutex
	closed  bool
	closeCh chan struct{}
	pending map[net.Conn]context.CancelFunc
}

// Start binds a loopback TCP listener on 127.0.0.1:0, generates an ephemeral Ed25519 CA
// certificate for mutual TLS authentication, and publishes a strict endpoint descriptor
// via internal/privatefile under directory.
//
// Prerequisites and Authority:
//   - Start must be called ONLY after the runtime owner already owns its exclusive host
//     application-state lock. It never acquires, modifies, or releases the runtime lock.
//   - directory must be an absolute path.
//
// Invariants:
//   - Binds TCP 127.0.0.1:0 and retains the underlying *net.TCPListener.
//   - Limits setup timeout (DefaultSetupTimeout = 5s) even without caller deadline.
//   - The context controls setup only; the listener and accepted connections survive setup context cancellation.
//   - On publication error, closes the listener and fails closed, preserving any
//     privatefile.PublishedSyncError uncertainty.
//   - Retains the descriptor file on disk when closed: stale presence never proves liveness,
//     and removal would race a subsequent runtime owner.
func Start(ctx context.Context, directory string) (*Listener, error) {
	if ctx == nil {
		return nil, errors.New("client/local: context is required")
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if !filepath.IsAbs(directory) {
		return nil, errors.New("client/local: directory must be an absolute path")
	}

	cleanDir := filepath.Clean(directory)

	setupCtx, cancelSetup := context.WithTimeout(ctx, DefaultSetupTimeout)
	defer cancelSetup()

	rawLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, fmt.Errorf("client/local: listen tcp: %w", err)
	}
	tcpLn, ok := rawLn.(*net.TCPListener)
	if !ok {
		_ = rawLn.Close()
		return nil, errors.New("client/local: unexpected listener type")
	}

	var listenerCreated *Listener
	defer func() {
		if listenerCreated == nil {
			_ = tcpLn.Close()
		}
	}()

	if err := setupCtx.Err(); err != nil {
		return nil, err
	}

	runID, certPEM, privPEM, tlsConfig, err := generateIdentity()
	if err != nil {
		return nil, fmt.Errorf("client/local: generate identity: %w", err)
	}

	endpoint := tcpLn.Addr().String()

	desc := &Descriptor{
		Version:        DescriptorVersion,
		RunID:          runID,
		Endpoint:       endpoint,
		CertificatePEM: certPEM,
		PrivateKeyPEM:  privPEM,
	}

	descBytes, err := desc.Encode()
	if err != nil {
		return nil, fmt.Errorf("client/local: encode descriptor: %w", err)
	}

	pf, err := privatefile.New(cleanDir, DescriptorFileName, LockFileName)
	if err != nil {
		return nil, err
	}

	err = pf.ReadModifyWrite(setupCtx, MaxDescriptorBytes, func(existing []byte) ([]byte, error) {
		return descBytes, nil
	})
	if err != nil {
		var syncErr *privatefile.PublishedSyncError
		if errors.As(err, &syncErr) {
			return nil, err
		}
		return nil, fmt.Errorf("client/local: publish descriptor: %w", err)
	}

	l := &Listener{
		tcpLn:     tcpLn,
		tlsConfig: tlsConfig,
		endpoint:  endpoint,
		runID:     runID,
		desc:      desc,
		closeCh:   make(chan struct{}),
		pending:   make(map[net.Conn]context.CancelFunc),
	}
	listenerCreated = l
	return l, nil
}

// Addr returns the underlying TCP listener network address.
func (l *Listener) Addr() net.Addr {
	return l.tcpLn.Addr()
}

// Endpoint returns the literal loopback host:port string (e.g. "127.0.0.1:45678").
func (l *Listener) Endpoint() string {
	return l.endpoint
}

// RunID returns the random run identifier for this listener instance.
func (l *Listener) RunID() string {
	return l.runID
}

// Descriptor returns a copy of the validated endpoint descriptor published by this listener.
func (l *Listener) Descriptor() *Descriptor {
	l.mu.Lock()
	defer l.mu.Unlock()
	cp := *l.desc
	cp.CertificatePEM = append([]byte(nil), l.desc.CertificatePEM...)
	cp.PrivateKeyPEM = append([]byte(nil), l.desc.PrivateKeyPEM...)
	return &cp
}

// Accept waits for and returns the next authenticated physical-client connection.
// It implements an explicit single-Accept contract guarded against concurrent invocations;
// concurrent calls return ErrAcceptInProgress immediately to eliminate global deadline races.
//
// Invariants:
//   - Returns authenticated net.Conn only; mutual TLS verification is completed before return.
//   - Handshake timeout is bounded; wrong or slow clients cannot monopolize the listener.
//   - Cancellation of ctx unblocks Accept promptly via stop-and-join watchers.
//   - On Listener.Close, pending handshakes are aborted and the listener is closed; already admitted
//     connections transfer to the caller and remain open.
//   - No per-packet goroutines or general message routing.
func (l *Listener) Accept(ctx context.Context) (net.Conn, error) {
	if ctx == nil {
		return nil, errors.New("client/local: context is required")
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}

	l.mu.Lock()
	if l.closed {
		l.mu.Unlock()
		return nil, ErrClosed
	}
	l.mu.Unlock()

	if !l.accepting.CompareAndSwap(false, true) {
		return nil, ErrAcceptInProgress
	}
	defer l.accepting.Store(false)

	acceptCtx, cancelAccept := context.WithCancel(ctx)
	defer cancelAccept()

	stopWatcher := watchCancellation(ctx, func() {
		cancelAccept()
		_ = l.tcpLn.SetDeadline(time.Now())
	})
	defer func() {
		stopWatcher()
		_ = l.tcpLn.SetDeadline(time.Time{})
	}()

	type rawResult struct {
		conn net.Conn
		err  error
	}
	rawCh := make(chan rawResult, 4)
	acceptWorkerDone := make(chan struct{})

	go func() {
		defer close(acceptWorkerDone)
		for {
			raw, err := l.tcpLn.Accept()
			if err != nil {
				select {
				case rawCh <- rawResult{err: err}:
				case <-acceptCtx.Done():
				case <-l.closeCh:
				}
				return
			}
			select {
			case rawCh <- rawResult{conn: raw}:
			case <-acceptCtx.Done():
				_ = raw.Close()
				return
			case <-l.closeCh:
				_ = raw.Close()
				return
			}
		}
	}()

	admittedCh := make(chan net.Conn, 1)
	var handshakesWg sync.WaitGroup
	slots := make(chan struct{}, maxPendingHandshakes)

	defer func() {
		cancelAccept()
		_ = l.tcpLn.SetDeadline(time.Now())
		<-acceptWorkerDone
		handshakesWg.Wait()
		// Only a connection actually returned to the caller transfers ownership.
		for {
			select {
			case item := <-rawCh:
				if item.conn != nil {
					abortConnection(item.conn)
				}
			default:
				goto admitted
			}
		}
	admitted:
		for {
			select {
			case conn := <-admittedCh:
				abortConnection(conn)
			default:
				return
			}
		}
	}()

	for {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()

		case <-l.closeCh:
			return nil, ErrClosed

		case item := <-rawCh:
			if item.err != nil {
				if ctx.Err() != nil {
					return nil, ctx.Err()
				}
				l.mu.Lock()
				closed := l.closed
				l.mu.Unlock()
				if closed {
					return nil, ErrClosed
				}
				var netErr net.Error
				if errors.As(item.err, &netErr) && netErr.Timeout() {
					if ctx.Err() != nil {
						return nil, ctx.Err()
					}
					return nil, ErrClosed
				}
				return nil, fmt.Errorf("client/local: accept tcp: %w", item.err)
			}

			select {
			case slots <- struct{}{}:
			default:
				abortConnection(item.conn)
				continue
			}
			handshakesWg.Add(1)
			go func(conn net.Conn) {
				defer handshakesWg.Done()
				defer func() { <-slots }()
				l.handshakeAndDeliver(acceptCtx, conn, admittedCh)
			}(item.conn)

		case admitted := <-admittedCh:
			if err := ctx.Err(); err != nil {
				abortConnection(admitted)
				return nil, err
			}
			return admitted, nil
		}
	}
}

func (l *Listener) handshakeAndDeliver(ctx context.Context, rawConn net.Conn, admittedCh chan<- net.Conn) {
	l.mu.Lock()
	if l.closed {
		l.mu.Unlock()
		_ = rawConn.Close()
		return
	}
	if len(l.pending) >= maxPendingHandshakes {
		l.mu.Unlock()
		_ = rawConn.Close()
		return
	}
	handshakeCtx, cancelHandshake := context.WithTimeout(ctx, DefaultHandshakeTimeout)
	l.pending[rawConn] = cancelHandshake
	l.mu.Unlock()

	defer func() {
		cancelHandshake()
		l.mu.Lock()
		delete(l.pending, rawConn)
		l.mu.Unlock()
	}()

	tlsConn := tls.Server(rawConn, l.tlsConfig)
	if err := tlsConn.HandshakeContext(handshakeCtx); err != nil {
		_ = rawConn.Close()
		return
	}

	state := tlsConn.ConnectionState()
	if !state.HandshakeComplete || len(state.PeerCertificates) == 0 {
		abortConnection(tlsConn)
		return
	}

	select {
	case admittedCh <- &connection{tlsConn}:
		// Successfully transferred to Accept caller.
	case <-ctx.Done():
		abortConnection(tlsConn)
	case <-l.closeCh:
		abortConnection(tlsConn)
	}
}

// Close closes the underlying TCP listener and aborts all owned pending handshakes.
// It is idempotent; subsequent calls return nil.
//
// Admitted connections already returned by Accept transfer to the caller and are NOT
// closed by Listener.Close.
//
// Descriptor retention:
// The descriptor file is intentionally NOT deleted from disk on Close. Deleting it
// could race a subsequent runtime owner, and stale presence never proves liveness.
func (l *Listener) Close() error {
	l.mu.Lock()
	if l.closed {
		l.mu.Unlock()
		return nil
	}
	l.closed = true
	close(l.closeCh)
	err := l.tcpLn.Close()
	for conn, cancel := range l.pending {
		cancel()
		_ = conn.Close()
	}
	clear(l.pending)
	l.mu.Unlock()
	return err
}

func generateIdentity() (string, []byte, []byte, *tls.Config, error) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return "", nil, nil, nil, fmt.Errorf("generate ed25519 key: %w", err)
	}

	serialNumberLimit := new(big.Int).Lsh(big.NewInt(1), 128)
	serialNumber, err := rand.Int(rand.Reader, serialNumberLimit)
	if err != nil {
		return "", nil, nil, nil, fmt.Errorf("generate serial number: %w", err)
	}

	now := time.Now()
	template := x509.Certificate{
		SerialNumber: serialNumber,
		Subject: pkix.Name{
			CommonName: "localhost",
		},
		NotBefore:             now.Add(-1 * time.Hour),
		NotAfter:              now.AddDate(10, 0, 0),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},
		BasicConstraintsValid: true,
		IsCA:                  true,
		DNSNames:              []string{"localhost"},
		IPAddresses:           []net.IP{net.IPv4(127, 0, 0, 1), net.IPv6loopback},
	}

	certDER, err := x509.CreateCertificate(rand.Reader, &template, &template, pub, priv)
	if err != nil {
		return "", nil, nil, nil, fmt.Errorf("create certificate: %w", err)
	}

	certPEM := pem.EncodeToMemory(&pem.Block{
		Type:  "CERTIFICATE",
		Bytes: certDER,
	})

	privDER, err := x509.MarshalPKCS8PrivateKey(priv)
	if err != nil {
		return "", nil, nil, nil, fmt.Errorf("marshal pkcs8 private key: %w", err)
	}

	privPEM := pem.EncodeToMemory(&pem.Block{
		Type:  "PRIVATE KEY",
		Bytes: privDER,
	})

	tlsCert, err := tls.X509KeyPair(certPEM, privPEM)
	if err != nil {
		return "", nil, nil, nil, fmt.Errorf("create tls keypair: %w", err)
	}

	certPool := x509.NewCertPool()
	if !certPool.AppendCertsFromPEM(certPEM) {
		return "", nil, nil, nil, errors.New("failed to append certificate to pool")
	}

	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{tlsCert},
		ClientAuth:   tls.RequireAndVerifyClientCert,
		ClientCAs:    certPool,
		MinVersion:   tls.VersionTLS13,
	}

	runIDBytes := make([]byte, 16)
	if _, err := io.ReadFull(rand.Reader, runIDBytes); err != nil {
		return "", nil, nil, nil, fmt.Errorf("generate run id: %w", err)
	}
	runID := hex.EncodeToString(runIDBytes)

	return runID, certPEM, privPEM, tlsConfig, nil
}

// Failed setup aborts the underlying transport without a graceful TLS write.
func abortConnection(conn net.Conn) {
	if secure, ok := conn.(*tls.Conn); ok {
		_ = secure.NetConn().Close()
		return
	}
	_ = conn.Close()
}
