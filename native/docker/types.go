// SPDX-License-Identifier: MIT

package docker

import (
	"github.com/wippyai/go-lua/types/io"
	"github.com/wippyai/go-lua/types/typ"
	luaexec "github.com/wippyai/runtime/runtime/lua/modules/exec"
)

func ModuleTypes() *io.Manifest {
	process, ok := luaexec.ModuleTypes().LookupType("Process")
	if !ok {
		panic("runtime exec.Process type is unavailable")
	}
	identity := typ.NewRecord().Field("container_id", typ.String).Field("image_id", typ.String).
		Field("started_at", typ.String).Field("labels", typ.NewMap(typ.String, typ.String)).Build()
	manifest := io.NewManifest("docker_pty")
	manifest.SetExport(typ.NewInterface("docker_pty", []typ.Method{
		{Name: "attach", Type: typ.Func().Param("identity", identity).Returns(typ.NewOptional(process), typ.NewOptional(typ.LuaError)).Build()},
	}))
	return manifest
}
