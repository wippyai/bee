// SPDX-License-Identifier: MIT

package local

import "crypto/tls"

// connection retains TLS reads/writes but makes detach independent of a peer
// reading close_notify. Display shutdown is an abort, not a graceful drain.
type connection struct{ *tls.Conn }

func (c *connection) Close() error {
	err := c.Conn.NetConn().Close()
	_ = c.Conn.Close()
	return err
}
