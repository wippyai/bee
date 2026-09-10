// SPDX-License-Identifier: MIT

package owner

import (
	"context"
	"net"

	"github.com/wippyai/go-lua/types/io"
	"github.com/wippyai/go-lua/types/typ"
	"github.com/wippyai/runtime/runtime/lua/engine"
)

// Security permission requirements.
const (
	SecurityAction   = "bee.local.accept"
	SecurityResource = "bee.local:listener"
)

// Connection bounds.
const (
	MaxConnections      = 32
	MaxOwnerConnections = 32
	closedBuffer        = 16
)

// Bounded fixed values for Closed.ErrorCode.
const (
	ErrorCodeOK             = ""
	ErrorCodeClosed         = "closed"
	ErrorCodeCanceled       = "canceled"
	ErrorCodeIOError        = "io_error"
	ErrorCodeProtocolError  = "protocol_error"
	ErrorCodeServiceStopped = "service_stopped"
	ErrorCodeViewportClosed = "viewport_closed"
)

const attachmentTypeName = "localdisplay.Attachment"

// Acceptor provides accepted net.Conn instances from an external listener.
// The listener factory and lifecycle are owned externally; owner does not
// close the listener upon attachment close or shutdown.
type Acceptor interface {
	Accept(ctx context.Context) (net.Conn, error)
}

// Closed represents a terminal closure event delivered to the Lua process.
// It is strictly typed with fixed bounded error codes; raw errors and tokens
// are never echoed.
type Closed struct {
	Kind      string `json:"kind"`
	ErrorCode string `json:"error_code"`
}

// ModuleTypes describes exported types of the localdisplay module to the type checker.
func ModuleTypes() *io.Manifest {
	closedRecord := typ.NewRecord().
		Field("kind", typ.LiteralString("closed")).
		Field("error_code", typ.NewUnion(
			typ.LiteralString(ErrorCodeOK),
			typ.LiteralString(ErrorCodeClosed),
			typ.LiteralString(ErrorCodeCanceled),
			typ.LiteralString(ErrorCodeIOError),
			typ.LiteralString(ErrorCodeProtocolError),
			typ.LiteralString(ErrorCodeServiceStopped),
			typ.LiteralString(ErrorCodeViewportClosed),
		)).
		Build()

	channel, ok := engine.ChannelModuleTypes().LookupType("Channel")
	if !ok {
		panic("runtime Channel type is unavailable")
	}
	generic, ok := channel.(*typ.Generic)
	if !ok {
		panic("runtime Channel type is not generic")
	}
	channelType := typ.Instantiate(generic, closedRecord)

	attachment := typ.NewInterface(attachmentTypeName, []typ.Method{
		{Name: "grant", Type: typ.Func().Param("self", typ.Self).Returns(typ.String).Build()},
		{Name: "channel", Type: typ.Func().Param("self", typ.Self).Returns(channelType).Build()},
		{Name: "close", Type: typ.Func().Param("self", typ.Self).Returns(typ.Boolean).Build()},
	})

	manifest := io.NewManifest("localdisplay")
	manifest.DefineType("Attachment", attachment)
	manifest.DefineType("Closed", closedRecord)
	manifest.SetExport(typ.NewInterface("localdisplay", []typ.Method{
		{
			Name: "accept",
			Type: typ.Func().
				Param("width", typ.Integer).
				Param("height", typ.Integer).
				Returns(typ.NewOptional(attachment), typ.NewOptional(typ.LuaError)).
				Build(),
		},
	}))
	return manifest
}
