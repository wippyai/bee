// SPDX-License-Identifier: MIT

package docker

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/moby/moby/client"
	lua "github.com/wippyai/go-lua"
	"github.com/wippyai/runtime/api/attrs"
	"github.com/wippyai/runtime/api/boot"
	ctxapi "github.com/wippyai/runtime/api/context"
	"github.com/wippyai/runtime/api/registry"
	secapi "github.com/wippyai/runtime/api/security"
	bootpkg "github.com/wippyai/runtime/boot"
	luaboot "github.com/wippyai/runtime/boot/components/runtime/lua"
	"github.com/wippyai/runtime/runtime/lua/code"
	secsystem "github.com/wippyai/runtime/system/security"
	"go.uber.org/zap"
)

type denyDockerAttachment struct{}

func (*denyDockerAttachment) ID() registry.ID { return registry.NewID("test", "docker-deny") }
func (*denyDockerAttachment) Evaluate(secapi.Actor, string, string, attrs.Bag) secapi.Result {
	return secapi.Deny
}

func TestComponentLoadsTypedModuleWithoutDaemonIO(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		http.Error(w, "daemon must not be contacted", http.StatusServiceUnavailable)
	}))
	defer server.Close()

	cli, err := client.New(client.WithHost("tcp://"+strings.TrimPrefix(server.URL, "http://")), client.WithAPIVersion("1.44"))
	if err != nil {
		t.Fatal(err)
	}
	defer cli.Close()

	ctx, err := bootpkg.NewBootstrapContext(zap.NewNop(), boot.NewConfig())
	if err != nil {
		t.Fatal(err)
	}
	manager, err := code.NewCodeManager(zap.NewNop(), nil, code.Config{})
	if err != nil {
		t.Fatal(err)
	}
	ctx = luaboot.SetCodeManager(ctx, manager)
	component, err := Component("private:docker", cli)
	if err != nil {
		t.Fatal(err)
	}
	ctx, err = component.Load(ctx)
	if err != nil {
		t.Fatal(err)
	}

	defs := manager.GetModuleDefs()
	if len(defs) != 1 || defs[0].Name != "docker_pty" {
		t.Fatalf("registered modules = %v, want docker_pty", defs)
	}
	manifest := defs[0].Types()
	if manifest == nil {
		t.Fatal("docker module has no type manifest")
	}
	if _, ok := manifest.LookupValue("attach"); !ok {
		t.Fatal("docker module attach type is not exposed")
	}

	ctx, frame := ctxapi.OpenFrameContext(ctx)
	defer frame.Close()
	if err := secapi.SetActor(ctx, secapi.Actor{ID: "unapproved"}); err != nil {
		t.Fatal(err)
	}
	if err := secapi.SetScope(ctx, secsystem.NewScope([]secapi.Policy{&denyDockerAttachment{}})); err != nil {
		t.Fatal(err)
	}
	table, _ := defs[0].Build()
	l := lua.NewState()
	defer l.Close()
	l.SetContext(ctx)
	l.SetGlobal("docker", table)
	expected := admitted()
	source := fmt.Sprintf(`local process, err = docker.attach({container_id=%q,image_id=%q,started_at=%q,labels={attempt="one"}})
assert(process == nil and err ~= nil)`, expected.ContainerID, expected.ImageID, expected.StartedAt)
	if err := l.DoString(source); err != nil {
		t.Fatal(err)
	}
	if requests.Load() != 0 {
		t.Fatalf("unauthorized attachment contacted daemon %d time(s)", requests.Load())
	}

	// A second Load of the same component must preserve the existing definition.
	if _, err := component.Load(ctx); err != nil {
		t.Fatalf("repeated component load: %v", err)
	}
	if got := len(manager.GetModuleDefs()); got != 1 {
		t.Fatalf("repeated load registered %d module definitions, want 1", got)
	}
	// A different host binding must not silently replace the daemon used by
	// already-loaded applications, even when it uses the same module name.
	other, err := Component("other:docker", cli)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := other.Load(ctx); err == nil {
		t.Fatal("conflicting Docker binding replaced the live module")
	}
	if current := manager.GetModuleDefs(); len(current) != 1 || current[0] != defs[0] {
		t.Fatal("refused registration changed the existing Docker binding")
	}
	if requests.Load() != 0 {
		t.Fatal("component registration contacted the Docker daemon")
	}
}

func TestComponentRequiresCodeManager(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "daemon must not be contacted", http.StatusServiceUnavailable)
	}))
	defer server.Close()
	cli, err := client.New(client.WithHost("tcp://"+strings.TrimPrefix(server.URL, "http://")), client.WithAPIVersion("1.44"))
	if err != nil {
		t.Fatal(err)
	}
	defer cli.Close()

	ctx, err := bootpkg.NewBootstrapContext(zap.NewNop(), boot.NewConfig())
	if err != nil {
		t.Fatal(err)
	}
	component, err := Component("private:docker", cli)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := component.Load(ctx); err == nil || !strings.Contains(err.Error(), "code manager") {
		t.Fatalf("missing code manager error = %v", err)
	}
}
