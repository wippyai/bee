// SPDX-License-Identifier: MIT

package ioevents

import (
	"github.com/wippyai/go-lua/types/io"
	"github.com/wippyai/go-lua/types/typ"
	"github.com/wippyai/runtime/runtime/lua/engine"
)

// ModuleTypes describes every exported value to the Wippy type checker.
func ModuleTypes() *io.Manifest {
	event := typ.NewRecord().Field("kind", typ.NewUnion(typ.LiteralString("change"), typ.LiteralString("rescan"))).Field("resource", typ.String).Field("path", typ.String).Field("operation", typ.String).Build()
	channel, ok := engine.ChannelModuleTypes().LookupType("Channel")
	if !ok {
		panic("runtime Channel type is unavailable")
	}
	generic, ok := channel.(*typ.Generic)
	if !ok {
		panic("runtime Channel type is not generic")
	}
	channelType := typ.Instantiate(generic, event)
	watch := typ.NewInterface(watchType, []typ.Method{
		{Name: "channel", Type: typ.Func().Param("self", typ.Self).Returns(channelType).Build()},
		{Name: "close", Type: typ.Func().Param("self", typ.Self).Returns(typ.Boolean).Build()},
	})
	manifest := io.NewManifest("ioevents")
	manifest.SetExport(typ.NewInterface("ioevents", []typ.Method{
		{Name: "watch", Type: typ.Func().Param("resource", typ.String).OptParam("path", typ.String).Returns(typ.NewOptional(watch), typ.NewOptional(typ.LuaError)).Build()},
	}))
	return manifest
}
