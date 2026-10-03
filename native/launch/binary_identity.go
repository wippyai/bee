// SPDX-License-Identifier: MIT

package launch

import (
	"encoding/json"
	"runtime/debug"
)

const (
	nativeModulePath = "github.com/wippyai/bee/native"
	runtimeCommit    = "5eb9901870e3a7ca72b608fc0f5e70b531d914b6"
)

type binaryIdentityFacts struct {
	NativeModule  string
	NativeVersion string
	NativeModules string
	RuntimeCommit string
}

func readBinaryIdentityFacts() binaryIdentityFacts {
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return binaryIdentityFacts{NativeModule: nativeModulePath, RuntimeCommit: runtimeCommit}
	}
	return binaryIdentityFromBuildInfo(info)
}

func binaryIdentityFromBuildInfo(info *debug.BuildInfo) binaryIdentityFacts {
	modules := make(map[string]string)
	if info != nil {
		if info.Main.Path != "" && info.Main.Version != "" {
			modules[info.Main.Path] = info.Main.Version
		}
		for _, dependency := range info.Deps {
			if dependency != nil && dependency.Path != "" && dependency.Version != "" {
				modules[dependency.Path] = dependency.Version
			}
		}
	}
	nativeVersion := modules[nativeModulePath]
	encoded, err := json.Marshal(modules)
	if err != nil {
		encoded = []byte("{}")
	}
	return binaryIdentityFacts{
		NativeModule:  nativeModulePath,
		NativeVersion: nativeVersion,
		NativeModules: string(encoded),
		RuntimeCommit: runtimeCommit,
	}
}
