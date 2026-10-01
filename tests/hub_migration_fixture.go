// MIT. Disposable Hub transport and artifacts for real Bee service acceptance.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"sort"
	"strings"

	module "github.com/wippyai/runtime/api/hub/wippy/api/hub/module/v1"
	"github.com/wippyai/runtime/api/semver"

	download "github.com/wippyai/runtime/api/hub/wippy/api/hub/download/v1"
	manifest "github.com/wippyai/runtime/api/hub/wippy/api/hub/manifest/v1"
	"github.com/wippyai/wapp"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
)

type artifact struct {
	body    []byte
	digest  string
	entries []wapp.Entry
}

func main() {
	var packages map[string][]wapp.Entry
	data, err := os.ReadFile(os.Args[1])
	must(err)
	must(json.Unmarshal(data, &packages))
	artifacts := map[string]artifact{}
	for key, entries := range packages {
		var packed bytes.Buffer
		must(wapp.NewWriter().PackEntries(wapp.Metadata{}, entries, &packed))
		sum := sha256.Sum256(packed.Bytes())
		artifacts[key] = artifact{packed.Bytes(), hex.EncodeToString(sum[:]), entries}
	}
	// Standalone acceptance serves sealed WAPP bytes, including resources.
	if len(os.Args) > 2 {
		var paths map[string]string
		data, err := os.ReadFile(os.Args[2])
		must(err)
		must(json.Unmarshal(data, &paths))
		for key, path := range paths {
			body, err := os.ReadFile(path)
			must(err)
			reader, err := wapp.NewReader(bytes.NewReader(body))
			must(err)
			entries, err := reader.GetEntries()
			must(err)
			sum := sha256.Sum256(body)
			artifacts[key] = artifact{body, hex.EncodeToString(sum[:]), entries}
		}
	}
	versions := func(component string) []string {
		result := []string{}
		for key := range artifacts {
			if strings.HasPrefix(key, component+"@") {
				result = append(result, strings.TrimPrefix(key, component+"@"))
			}
		}
		sort.Slice(result, func(i, j int) bool {
			a, _ := semver.ParseVersion(result[i])
			b, _ := semver.ParseVersion(result[j])
			return a.GreaterThan(b)
		})
		return result
	}
	selectVersion := func(component, constraint string) string {
		if _, ok := artifacts[component+"@"+constraint]; ok {
			return constraint
		}
		parsed, err := semver.ParseConstraint(constraint)
		must(err)
		for _, version := range versions(component) {
			value, err := semver.ParseVersion(version)
			must(err)
			if parsed.Match(value) {
				return version
			}
		}
		panic("no fixture candidate for " + component + " " + constraint)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	must(err)
	base := "http://" + listener.Addr().String()
	info := func(key string) map[string]any {
		item, ok := artifacts[key]
		if !ok {
			panic("unknown fixture artifact " + key)
		}
		return map[string]any{"url": base + "/artifact/" + key, "digest": item.digest, "sizeBytes": len(item.body)}
	}
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/artifact/") {
			item, ok := artifacts[strings.TrimPrefix(r.URL.Path, "/artifact/")]
			if !ok {
				http.NotFound(w, r)
				return
			}
			_, _ = w.Write(item.body)
			return
		}
		var request, response proto.Message
		switch {
		case strings.HasSuffix(r.URL.Path, "/GetDownloadURL"):
			request, response = &download.GetDownloadURLRequest{}, &download.GetDownloadURLResponse{}
		case strings.HasSuffix(r.URL.Path, "/ListVersions"):
			request, response = &module.ListVersionsRequest{}, &module.ListVersionsResponse{}
		case strings.HasSuffix(r.URL.Path, "/ListModules"):
			request, response = &module.ListModulesRequest{}, &module.ListModulesResponse{}
		case strings.HasSuffix(r.URL.Path, "/GetManifest"):
			request, response = &manifest.GetManifestRequest{}, &manifest.GetManifestResponse{}
		default:
			http.Error(w, "unsupported fixture RPC "+r.URL.Path, 404)
			return
		}
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, err.Error(), 400)
			return
		}
		if strings.Contains(r.Header.Get("Content-Type"), "json") {
			err = protojson.Unmarshal(body, request)
		} else {
			err = proto.Unmarshal(body, request)
		}
		if err != nil {
			http.Error(w, err.Error(), 400)
			return
		}
		encoded, err := protojson.Marshal(request)
		must(err)
		var value struct {
			Module  struct{ Name struct{ Org, Name string } }
			Version struct{ Version string }
		}
		must(json.Unmarshal(encoded, &value))
		component := value.Module.Name.Org + "/" + value.Module.Name.Name
		version := value.Version.Version
		key := component + "@" + version
		item, ok := artifacts[key]
		if !ok && !strings.HasSuffix(r.URL.Path, "/ListVersions") && !strings.HasSuffix(r.URL.Path, "/ListModules") {
			http.Error(w, "unknown artifact "+key, 404)
			return
		}
		var result map[string]any
		if _, ok := response.(*module.ListVersionsResponse); ok {
			rows := []any{}
			for _, version := range versions(component) {
				rows = append(rows, map[string]any{"version": version})
			}
			result = map[string]any{"versions": rows, "total": len(rows), "page": 1, "pageSize": 100}
		} else if _, ok := response.(*module.ListModulesResponse); ok {
			rows := []any{}
			seen := map[string]bool{}
			names := []string{}
			for key := range artifacts {
				name := strings.SplitN(key, "@", 2)[0]
				if strings.HasPrefix(name, "bee/") && !seen[name] {
					seen[name] = true
					names = append(names, name)
				}
			}
			sort.Strings(names)
			for _, name := range names {
				parts := strings.SplitN(name, "/", 2)
				rows = append(rows, map[string]any{"name": parts[1], "organizationName": parts[0], "displayName": name, "latestVersion": versions(name)[0]})
			}
			result = map[string]any{"modules": rows, "total": len(rows), "page": 1, "pageSize": 50}
		} else if _, ok := response.(*download.GetDownloadURLResponse); ok {
			result = map[string]any{"version": version, "download": info(key)}
		} else {
			deps := []any{}
			for _, entry := range item.entries {
				if entry.Kind != "ns.dependency" {
					continue
				}
				fields := entry.Data.(map[string]any)
				dep := fields["component"].(string)
				constraint := fields["version"].(string)
				selected := selectVersion(dep, constraint)
				parts := strings.SplitN(dep, "/", 2)
				target := artifacts[dep+"@"+selected]
				deps = append(deps, map[string]any{"org": parts[0], "name": parts[1], "version": selected, "versionId": selected, "constraint": constraint, "digest": target.digest, "sizeBytes": len(target.body), "download": info(dep + "@" + selected)})
			}
			result = map[string]any{"manifest": map[string]any{"org": value.Module.Name.Org, "name": value.Module.Name.Name, "version": version, "versionId": version, "digest": item.digest, "sizeBytes": len(item.body), "download": info(key), "dependencies": deps}}
		}
		payload, err := json.Marshal(result)
		must(err)
		must(protojson.Unmarshal(payload, response))
		if strings.Contains(r.Header.Get("Content-Type"), "json") {
			payload, err = protojson.Marshal(response)
			w.Header().Set("Content-Type", "application/json")
		} else {
			payload, err = proto.Marshal(response)
			w.Header().Set("Content-Type", "application/proto")
		}
		must(err)
		_, _ = w.Write(payload)
	})
	fmt.Println(base)
	must(http.Serve(listener, handler))
}
func must(err error) {
	if err != nil {
		panic(err)
	}
}
