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
	ctxapi "github.com/wippyai/runtime/api/context"
	"github.com/wippyai/runtime/api/registry"
	secapi "github.com/wippyai/runtime/api/security"
	secsystem "github.com/wippyai/runtime/system/security"
)

type attachmentPolicy struct {
	resource string
	expected Identity
}

func (*attachmentPolicy) ID() registry.ID { return registry.NewID("test", "attach") }
func (p *attachmentPolicy) Evaluate(actor secapi.Actor, action, resource string, meta attrs.Bag) secapi.Result {
	if actor.ID == "admitted" && action == "docker.attach" && resource == p.resource && meta["image_id"] == p.expected.ImageID && meta["started_at"] == p.expected.StartedAt {
		return secapi.Allow
	}
	return secapi.Deny
}
func TestLuaAttachmentAdmissionBeforeDaemonIO(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		http.Error(w, "fixture daemon refusal", 503)
	}))
	defer server.Close()
	cli, err := client.New(client.WithHost("tcp://"+strings.TrimPrefix(server.URL, "http://")), client.WithAPIVersion("1.44"))
	if err != nil {
		t.Fatal(err)
	}
	defer cli.Close()
	expected := admitted()
	request := fmt.Sprintf(`{container_id=%q,image_id=%q,started_at=%q,labels={attempt="one"}}`, expected.ContainerID, expected.ImageID, expected.StartedAt)
	for _, tc := range []struct {
		name, actor, daemon, resource, suffix string
		scope, allow                          bool
	}{
		{name: "allowed", actor: "admitted", daemon: "host:docker", resource: "host:docker/" + expected.ContainerID, scope: true, allow: true},
		{name: "other-container", actor: "admitted", daemon: "host:docker", resource: "host:docker/" + strings.Repeat("c", 64), scope: true},
		{name: "other-daemon", actor: "admitted", daemon: "other:docker", resource: "host:docker/" + expected.ContainerID, scope: true},
		{name: "other-actor", actor: "other", daemon: "host:docker", resource: "host:docker/" + expected.ContainerID, scope: true},
		{name: "missing-actor", daemon: "host:docker", scope: true},
		{name: "missing-scope", actor: "admitted", daemon: "host:docker"},
		{name: "caller-url", actor: "admitted", daemon: "host:docker", resource: "host:docker/" + expected.ContainerID, scope: true, suffix: `request.daemon="tcp://attacker:2375"`},
		{name: "bad-label", actor: "admitted", daemon: "host:docker", resource: "host:docker/" + expected.ContainerID, scope: true, suffix: `request.labels[1]="not-a-label"`},
		{name: "changed-start", actor: "admitted", daemon: "host:docker", resource: "host:docker/" + expected.ContainerID, scope: true, suffix: `request.started_at="2026-09-13T12:00:01Z"`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx, frame := ctxapi.OpenFrameContext(ctxapi.NewRootContext())
			defer frame.Close()
			if tc.actor != "" {
				if err := secapi.SetActor(ctx, secapi.Actor{ID: tc.actor}); err != nil {
					t.Fatal(err)
				}
			}
			if tc.scope {
				if err := secapi.SetScope(ctx, secsystem.NewScope([]secapi.Policy{&attachmentPolicy{resource: tc.resource, expected: expected}})); err != nil {
					t.Fatal(err)
				}
			}
			module, err := NewModule(tc.daemon, cli)
			if err != nil {
				t.Fatal(err)
			}
			table, _ := module.Build()
			l := lua.NewState()
			defer l.Close()
			l.SetContext(ctx)
			l.SetGlobal("docker", table)
			source := "local request=" + request + "\n" + tc.suffix + "\nlocal child, err = docker.attach(request)\n"
			if tc.allow {
				source += `assert(child ~= nil and err == nil); assert(type(child.attach_terminal) == "function"); child:close()`
			} else {
				source += `assert(child == nil and err ~= nil)`
			}
			if err := l.DoString(source); err != nil {
				t.Fatal(err)
			}
			if requests.Load() != 0 {
				t.Fatal("admission or refusal contacted daemon")
			}
		})
	}
}
func TestRejectsUnboundDockerModule(t *testing.T) {
	// Construction must reject incomplete host bindings before a Lua table exists.
	if m, err := NewModule("", nil); m != nil || err == nil {
		t.Fatal("unbound module admitted")
	}
}
