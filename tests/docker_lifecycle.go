// SPDX-License-Identifier: MIT
// Real Docker lifecycle through the registered Bee operations and placement store.
// Uses an already-local image, no network or user credentials, and disposable state.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func run() error {
	runtime := flag.String("runtime", "", "Bee runtime")
	dockerSource := flag.String("docker-source", "", "userspace Docker client package")
	image := flag.String("image", "", "already-local immutable image with /bin/sh and sleep")
	socket := flag.String("socket", "/var/run/docker.sock", "local daemon socket")
	flag.Parse()
	if *runtime == "" || *dockerSource == "" || !strings.HasPrefix(*image, "sha256:") || len(*image) != 71 || os.Getuid() == 0 || os.Getgid() == 0 {
		return fmt.Errorf("runtime, Docker client, immutable image and non-root user required")
	}
	fixtureParent, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	root, err := os.MkdirTemp(fixtureParent, ".bee-docker-lifecycle-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
	for dst, src := range map[string]string{"src": "src", "src/docker_daemon": "modules/bee-placement-docker-daemon/src", "src/docker_client": *dockerSource} {
		if err := os.CopyFS(filepath.Join(root, dst), os.DirFS(src)); err != nil {
			return err
		}
	}
	attempt := filepath.Base(root)
	owner := "bee.docker_acceptance"
	digest := sha256.Sum256([]byte("attempt/" + owner + "\n" + attempt))
	placementRoot := filepath.Join(root, "placement")
	home := filepath.Join(placementRoot, "attempts", hex.EncodeToString(digest[:])[:32], "home")
	project := filepath.Join(root, "project")
	for _, dir := range []string{"home", "config", "data", "state", "project", "evidence"} {
		if err := os.MkdirAll(filepath.Join(root, dir), 0700); err != nil {
			return err
		}
	}
	// Cleanup is independently bounded and scoped to this unpredictable attempt label.
	transport := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", *socket)
	}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 10 * time.Second}
	defer func() {
		filters, _ := json.Marshal(map[string][]string{"label": {"bee.attempt_id=" + attempt}})
		req, _ := http.NewRequest("GET", "http://docker/containers/json", nil)
		q := req.URL.Query()
		q.Set("all", "true")
		q.Set("filters", string(filters))
		req.URL.RawQuery = q.Encode()
		response, e := client.Do(req)
		if e != nil {
			fmt.Fprintln(os.Stderr, "fixture cleanup list:", e)
			return
		}
		defer response.Body.Close()
		var containers []struct {
			ID     string `json:"Id"`
			Labels map[string]string
		}
		if response.StatusCode != 200 || json.NewDecoder(response.Body).Decode(&containers) != nil {
			return
		}
		for _, c := range containers {
			if len(c.ID) != 64 || c.Labels["bee.attempt_id"] != attempt {
				continue
			}
			r, _ := http.NewRequest("DELETE", "http://docker/containers/"+c.ID+"?force=true", nil)
			res, e := client.Do(r)
			if e != nil {
				fmt.Fprintln(os.Stderr, "fixture cleanup:", e)
			} else {
				res.Body.Close()
			}
		}
	}()
	policy := map[string]any{"schema_revision": "bee.launch-policy@2", "placement_binding": "bee.placement.docker:binding", "required_cleanup": "contained_tree", "required_exit_observation": "independent", "start_ms": 10000, "stop_grace_ms": 500, "drain_ms": 1000, "runner_drain_ms": 500, "fixture": true, "executables": map[string]string{}, "environment": map[string]string{}, "docker": map[string]any{"image": *image, "user": fmt.Sprintf("%d:%d", os.Getuid(), os.Getgid()), "network": "none", "memory": 134217728, "nano_cpus": 1000000000, "pids_limit": 32, "home_target": home, "mounts": []map[string]string{{"source": project, "target": project, "access": "read"}}}}
	policyJSON, _ := json.Marshal(policy)
	socketJSON, _ := json.Marshal(*socket)
	manifest := `version: '1.0'
namespace: bee.docker_acceptance
entries:
- name: policy
  kind: registry.entry
  meta: {type: bee.launch_policy}
  data: ` + string(policyJSON) + `
- name: allow
  kind: security.policy
  policy: {actions: '*', resources: '*', effect: allow}
- name: driver
  kind: contract.binding
  meta: {type: harness.driver, driver_id: docker_acceptance}
  contracts:
  - contract: bee.driver:driver
    methods: {configure: 'bee.docker_acceptance:configure', prepare: 'bee.docker_acceptance:configure', dispatch: 'bee.docker_acceptance:configure', normalize: 'bee.docker_acceptance:configure'}
- name: configure
  kind: function.lua
  source: file://configure.lua
  method: handle
- name: output
  kind: fs.directory
  directory: ` + filepath.Join(root, "evidence") + `
- name: check
  kind: process.lua
  source: file://check.lua
  method: main
  modules: [funcs, security, registry, fs, process, json]
  imports: {resolver: 'bee.placement:resolver', bounds: 'bee.threads.records:bounds'}
  meta: {command: {name: docker-lifecycle-check, security: {actor: {id: bee.docker_acceptance}, policies: [bee.docker_acceptance:allow]}}}
`
	daemonHost := `version: '1.0'
namespace: bee.placement.docker.daemon
entries:
- name: daemon_ref
  kind: registry.entry
  data: {resource_ref: 'bee.placement.docker.daemon:fixture_socket'}
- name: fixture_socket
  kind: registry.entry
  meta: {type: bee.docker_daemon}
  data: {socket_path: ` + string(socketJSON) + `}
`
	script := strings.ReplaceAll(lifecycleLua, "ATTEMPT", attempt)
	for path, contents := range map[string]string{"src/docker_acceptance/_index.yaml": manifest, "src/docker_acceptance/check.lua": script, "src/docker_acceptance/configure.lua": `return {handle=function(_:unknown): {[string]:unknown} return {ok=true, delivery={arguments={},files={}}} end}`, "src/docker_host/_index.yaml": daemonHost, "wippy.lock": "directories:\n  src: src\n  modules: .wippy\n"} {
		full := filepath.Join(root, path)
		if err := os.MkdirAll(filepath.Dir(full), 0700); err != nil {
			return err
		}
		if err := os.WriteFile(full, []byte(contents), 0600); err != nil {
			return err
		}
	}
	env := append(os.Environ(), "HOME="+filepath.Join(root, "home"), "XDG_CONFIG_HOME="+filepath.Join(root, "config"), "XDG_DATA_HOME="+filepath.Join(root, "data"), "XDG_STATE_HOME="+filepath.Join(root, "state"), "BEE_PLACEMENT_ROOT="+placementRoot)
	for _, name := range []string{"workspace", "threads", "approvals", "resources", "credentials", "placement", "gateway", "node", "governance"} {
		env = append(env, "BEE_"+strings.ToUpper(name)+"_DB="+filepath.Join(root, name+".db"))
	}
	for _, args := range [][]string{{"lint", "--set", "lua.type_system.enabled=true", "--set", "lua.type_system.strict=true"}, {"run", "docker-lifecycle-check"}, {"run", "docker-lifecycle-check"}} {
		ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
		cmd := exec.CommandContext(ctx, *runtime, args...)
		cmd.Dir = root
		cmd.Env = env
		out, e := cmd.CombinedOutput()
		cancel()
		if e != nil {
			return fmt.Errorf("%s failed: %w\n%s", args[0], e, out)
		}
	}
	proof, err := os.ReadFile(filepath.Join(root, "evidence", "complete"))
	if err != nil || string(proof) != "DOCKER_LIFECYCLE_COMPLETE" {
		return fmt.Errorf("missing lifecycle completion proof: %v", err)
	}
	fmt.Println("PASS: real registered Docker lifecycle survives Bee restart with the same container; foreign/old attachments refused and cleanup confirmed")
	return nil
}

const lifecycleLua = `local json=require("json")
local funcs=require("funcs")
local security=require("security")
local registry=require("registry")
local resolver=require("resolver")
local bounds=require("bounds")
local fs=require("fs")
local process=require("process")
local function call(method:string,request:unknown,foreign:boolean?): {[string]:unknown}
 local runner=funcs.new()
 if foreign then runner=runner:with_actor(security.new_actor("foreign")):with_scope(security.new_scope({assert(security.policy("bee.docker_acceptance:allow"))})) end
 local raw,err=runner:call("bee.placement.docker:"..method,request)
 if err then error(method..": "..tostring(err)) end
 local reply=bounds.object(raw)
 if not reply then error(method..": no reply") end
 return reply
end
local function value(method:string,request:unknown): {[string]:unknown}
 local reply=call(method,request)
 if reply.ok~=true then local fault=bounds.object(reply.error) or {};error(method..": "..tostring(fault.code)..": "..tostring(fault.message)) end
 local result=bounds.object(reply.value);if not result then error(method..": invalid value") end
 return result
end
local function main()
 local activation=assert(registry.get("bee:harness_activation"))
 activation.data.bindings={"bee.docker_acceptance:driver"}
 local changes=registry.snapshot():changes();changes:update(activation);assert(changes:apply())
 local binding,err=resolver.resolve(registry.snapshot(),"bee.placement.docker:binding")
 if not binding then error(tostring(err)) end
 local request={idempotency_key="ATTEMPT",owner_id="bee.docker_acceptance",owner_incarnation=1,action_id="ATTEMPT-action",attempt_id="ATTEMPT",
 binding_ref="bee.docker_acceptance:driver",policy_ref="bee.docker_acceptance:policy",profile_id="window",binding_digest=string.rep("b",64),profile_digest=string.rep("c",64),
 placement_binding_ref=binding.binding_id,placement_binding_digest=binding.binding_digest,
 launch={executable="/bin/sh",argv={"-c","while :; do sleep 1; done"},environment={},readiness="none"},resources={},environment={},required_cleanup="contained_tree",required_exit_observation="independent",timeouts={start_ms=10000,stop_grace_ms=500}}
 local denied=call("prepare",request,true);assert(denied.ok==false,"foreign preparation admitted")
 local output=assert(fs.get("bee.docker_acceptance:output"))
 local resuming=output:exists("/started")
 local prepared=value("prepare",request);assert(prepared.execution_state==(resuming and "running" or "intended"))
 local replay=value("prepare",request);assert(replay.attempt_id==prepared.attempt_id,"prepare replay changed identity")
 local generation=resuming and 2 or 1
 value("attach",{attempt_id="ATTEMPT",recipient=process.pid(),generation=generation})
 if not resuming then local started=value("start",{attempt_id="ATTEMPT"});assert(started.execution_state=="running") end
 local foreign=call("status",{attempt_id="ATTEMPT"},true);assert(foreign.ok==false,"foreign inspection admitted")
 local internal=call("reconcile_internal",{attempt_id="ATTEMPT"});assert(internal.ok==false,"ordinary caller reconciled as sweeper")
 local stale=call("container_identity",{attempt_id="ATTEMPT",recipient=process.pid(),generation=generation+1});assert(stale.ok==false,"stale attachment admitted")
 local identity=value("container_identity",{attempt_id="ATTEMPT",recipient=process.pid(),generation=generation});assert(type(identity.container_id)=="string")
 if not resuming then
  local saved=assert(json.encode({container_id=identity.container_id,started_at=identity.started_at,recipient=process.pid()}))
  assert(output:writefile_atomic("/started",saved))
  return true
 end
 local saved=bounds.object(assert(json.decode(assert(output:readfile("/started")))))
 assert(saved and saved.container_id==identity.container_id and saved.started_at==identity.started_at,"restart replaced container execution")
 local old=call("container_identity",{attempt_id="ATTEMPT",recipient=saved.recipient,generation=1});assert(old.ok==false,"old recipient retained attachment after restart")
 local stopped=value("stop",{attempt_id="ATTEMPT",mode="cooperative"});assert(stopped.execution_state=="exited")
 local cleaned=value("cleanup",{attempt_id="ATTEMPT"});assert(cleaned.cleanup_state=="complete")
 local repeated=value("cleanup",{attempt_id="ATTEMPT"});assert(repeated.cleanup_state=="complete")
 assert(output:writefile_atomic("/complete","DOCKER_LIFECYCLE_COMPLETE"))
 return true
end
return {main=main}
`
