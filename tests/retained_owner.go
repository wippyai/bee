// SPDX-License-Identifier: MIT
// Verify retained owner composition and supervised definition replacement.
package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"
)

var retainedID = regexp.MustCompile(`^[0-9a-f]{32}$`)

func validReceipt(line string) bool {
	fields := strings.Fields(line)
	if len(fields) != 6 || fields[0] != "BEE_RETAINED_OWNER_READY" {
		return false
	}
	if fields[1] == "local" {
		return fields[2] == "-" && fields[3] != "" && retainedID.MatchString(fields[4]) && retainedID.MatchString(fields[5])
	}
	return fields[1] != "" && fields[2] != "" && fields[2] != "-" && fields[3] != "" && retainedID.MatchString(fields[4]) && retainedID.MatchString(fields[5])
}

func databaseEnvironment(root string) []string {
	names := []string{"workspace", "threads", "approvals", "resources", "credentials", "gateway", "placement", "node", "governance", "sync"}
	environment := make([]string, 0, len(names)+2)
	for _, name := range names {
		environment = append(environment, "BEE_"+strings.ToUpper(name)+"_DB="+filepath.Join(root, name+".db"))
	}
	return append(environment, "BEE_CLIENT_DB="+filepath.Join(root, "client.db"), "BEE_PLACEMENT_ROOT="+filepath.Join(root, "placement"))
}

func boot(runtime, root string, configs ...string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	args := []string{"run", "--verbose", "--host", "bee:terminal"}
	for _, config := range configs {
		args = append(args, "--config", config)
	}
	args = append(args, "--", "bee-owner")
	command := exec.CommandContext(ctx, runtime, args...)
	command.Dir = root
	command.Env = append(os.Environ(), databaseEnvironment(root)...)
	stdout, err := command.StdoutPipe()
	if err != nil {
		return err
	}
	command.Stderr = command.Stdout
	if err := command.Start(); err != nil {
		return err
	}
	ready := make(chan struct{}, 1)
	scanned := make(chan struct{})
	var lines []string
	go func() {
		defer close(scanned)
		scanner := bufio.NewScanner(stdout)
		for scanner.Scan() {
			line := scanner.Text()
			lines = append(lines, line)
			if validReceipt(line) {
				select {
				case ready <- struct{}{}:
				default:
				}
			}
		}
	}()
	select {
	case <-ready:
	case <-scanned:
		waitErr := command.Wait()
		return fmt.Errorf("retained owner exited before ready: %v\n%s", waitErr, strings.Join(lines, "\n"))
	case <-ctx.Done():
		_ = command.Wait()
		<-scanned
		return fmt.Errorf("retained owner receipt timeout:\n%s", strings.Join(lines, "\n"))
	}
	if err := command.Process.Signal(syscall.SIGTERM); err != nil {
		cancel()
		_ = command.Wait()
		<-scanned
		return err
	}
	err = command.Wait()
	<-scanned
	var exited *exec.ExitError
	if !errors.As(err, &exited) || exited.ExitCode() != 1 || !strings.Contains(strings.Join(lines, "\n"), "force exit") {
		return fmt.Errorf("retained owner direct shutdown: %w\n%s", err, strings.Join(lines, "\n"))
	}
	return nil
}

func stop(runtime, root string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	args := []string{"run", "--verbose", "--", "bee-retained-owner-probe"}
	command := exec.CommandContext(ctx, runtime, args...)
	command.Dir = root
	command.Env = append(os.Environ(), databaseEnvironment(root)...)
	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("retained owner cancellation probe: %w\n%s", err, output)
	}
	if !strings.Contains(string(output), "BEE_RETAINED_OWNER_STOPPED") {
		return fmt.Errorf("retained owner did not stop cleanly:\n%s", output)
	}
	return nil
}

const probeIndex = `version: '1.0'
namespace: bee.retained_owner_probe
entries:
- name: probe_policy
  kind: security.policy.expr
  policy:
    expression: '((action == "process.spawn" || action == "process.spawn.monitored") && resource == "bee.launch:owner") || (action == "process.host" && resource == "bee:terminal") || (action == "process.cancel" && resource matches "^\\{[^}]+@bee:terminal\\|0x[0-9a-f]+\\}$") || action == "process.context" || action == "process.security" || action == "security.policy.get" || action == "security.scope.create" || action == "registry.get" || action == "registry.snapshot" || action == "registry.apply"'
    actions: [process.spawn, process.spawn.monitored, process.host, process.cancel, process.context, process.security, security.policy.get, security.scope.create, registry.get, registry.snapshot, registry.apply]
    resources: ['*']
    effect: allow
- name: main
  kind: process.lua
  source: file://main.lua
  method: main
  modules: [process, security, channel, time, io, registry]
  imports:
    decode: bee.protocol:decode
  security:
    policies: [bee.retained_owner_probe:probe_policy]
  meta:
    command:
      name: bee-retained-owner-probe
      host: bee:terminal
      short: Verify retained owner startup and cancellation
      security:
        actor: {id: bee.retained_owner_probe}
`

const probeSource = `local process = require("process")
local security = require("security")
local channel = require("channel")
local time = require("time")
local io = require("io")
local registry = require("registry")
local decode = require("decode")

local function main()
    local events, events_error = process.events()
    if not events then error(tostring(events_error)) end
    local started, started_error = process.listen("bee.retained_owner_probe.ready", {message = true})
    if not started then error(tostring(started_error)) end
    local workspace_ready = assert(process.listen("bee.retained_owner_probe.workspace_ready", {message = true}))
    local controllers = assert(process.listen("bee.retained_owner_probe.controller_ready", {message = true}))
    local policies: {security.Policy} = {}
    for _, name in ipairs({"bee.security.desktop:desktop_policy", "bee.security.desktop:retained_owner_spawn_policy", "bee.security.desktop:retained_owner_name_policy", "bee.security.desktop:retained_owner_node_policy", "bee.security.desktop:owner_command_stop_policy"}) do
        local policy, policy_error = security.policy(name)
        if not policy then error(tostring(policy_error)) end
        policies[#policies + 1] = policy
    end
    local owner, owner_error = process.with_options({}):with_context({["bee.owner_probe"] = tostring(process.pid())})
        :with_scope(security.new_scope(policies)):spawn_monitored("bee.launch:owner", "bee:terminal")
    if not owner then error(tostring(owner_error)) end
    local startup_guard = time.after("120s")
    local selected = channel.select({started:case_receive(), events:case_receive(), startup_guard:case_receive()})
    if not selected.ok or selected.channel ~= started or tostring(selected.value:from()) ~= tostring(owner) then
        error("Retained owner did not register its command before cancellation")
    end
    process.unlisten(started)
    local live = channel.select({workspace_ready:case_receive(), events:case_receive(), startup_guard:case_receive()})
    assert(live.ok and live.channel == workspace_ready and tostring(live.value:from()) == tostring(owner),
        "Retained workspace did not become ready")
    local old = channel.select({controllers:case_receive(), events:case_receive(), startup_guard:case_receive()})
    assert(old.ok and old.channel == controllers and tostring(old.value:from()) == tostring(owner),
        "Owner controller did not become ready")
    local old_value: unknown = old.value:payload():data()
    assert(type(old_value) == "table" and type(old_value.pid) == "string")
    for revision = 1, 3 do
        local definition = assert(registry.get("bee.launch:owner"))
        definition.meta.handoff_probe = "owner-definition-changed-" .. tostring(revision)
        local changes = assert(registry.snapshot()):changes()
        changes:update(definition)
        assert(changes:apply())
        local changed = channel.select({controllers:case_receive(), events:case_receive(), time.after("10s"):case_receive()})
        assert(changed.ok and changed.channel == controllers and tostring(changed.value:from()) == tostring(owner),
            "Owner controller did not replace after definition change")
        local new_value: unknown = changed.value:payload():data()
        assert(type(new_value) == "table" and type(new_value.pid) == "string" and new_value.pid ~= old_value.pid,
            "Owner controller kept its outdated definition")
        old_value = new_value
    end
    assert(io.print("BEE_RETAINED_OWNER_STOPPING"))
    local stopped, stopped_error = process.cancel(owner, "retained owner acceptance")
    if not stopped then error(tostring(stopped_error)) end
    local deadline = time.after("120s")
    while true do
        selected = channel.select({events:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then error("Retained owner did not stop") end
        local event = selected.value
        if event.kind == process.event.EXIT and tostring(event.from) == tostring(owner) then
            local exit_error = decode.exit_error(event.result)
            if exit_error then error("Retained owner exit: " .. exit_error) end
            assert(io.print("BEE_RETAINED_OWNER_STOPPED"))
            return
        end
    end
end

return {main = main}
`

// desktopAdmission is the host configuration the native owner selects: the
// Hive supervisor's desktop bridge admits local clients and composes the
// retained workspace, so the owner route must learn readiness from the bridge.
func desktopAdmission(root string) (string, error) {
	expires := time.Now().Add(time.Hour).UTC().Format("2006-01-02T15:04:05.000Z07:00")
	config := fmt.Sprintf(`version: "1.0"
override:
  "bee.hive_host:supervisor_service:input":
  - configured_nodes: []
    desktop:
      execution: %s
      expires_at: "%s"
      allowed_nodes: []
      local_clients: true
`, strings.Repeat("a", 32), expires)
	path := filepath.Join(root, "desktop-admission.yaml")
	return path, os.WriteFile(path, []byte(config), 0600)
}

func writeProbe(root string) error {
	directory := filepath.Join(root, "src", "retained_owner_probe")
	if err := os.MkdirAll(directory, 0700); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(directory, "_index.yaml"), []byte(probeIndex), 0600); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(directory, "main.lua"), []byte(probeSource), 0600); err != nil {
		return err
	}
	// Only this disposable source copy reports the command-registration event
	// to its probe; the ordinary boot path and portable deployment do not signal.
	ownerPath := filepath.Join(root, "src", "launch", "owner.lua")
	owner, err := os.ReadFile(ownerPath)
	if err != nil {
		return err
	}
	code := string(owner)
	entry := "local function main(controller_owner: string?, controller_checkpoint: unknown?)"
	registration := "    if not stops then error(stops_error) end"
	controllerReady := "                    if not resumed then error(\"Owner controller did not validate its checkpoint\") end"
	workspaceReady := "                    checkpoint = handoff.pack(self, value.workspace_id, value.desktop_id)"
	if strings.Count(code, entry) != 1 || strings.Count(code, registration) != 1 || strings.Count(code, controllerReady) != 1 || strings.Count(code, workspaceReady) != 1 {
		return fmt.Errorf("retained owner probe injection point changed")
	}
	code = strings.Replace(code, entry, entry+"\n    local probe_pid = ctx.get(\"bee.owner_probe\")", 1)
	code = strings.Replace(code, registration, registration+"\n    if type(probe_pid) == \"string\" then assert(process.send(probe_pid, \"bee.retained_owner_probe.ready\", {})) end", 1)
	code = strings.Replace(code, controllerReady, controllerReady+"\n                    if type(probe_pid) == \"string\" then assert(process.send(probe_pid, \"bee.retained_owner_probe.controller_ready\", {pid = controller_pid})) end", 1)
	code = strings.Replace(code, workspaceReady, workspaceReady+"\n                    if type(probe_pid) == \"string\" then assert(process.send(probe_pid, \"bee.retained_owner_probe.workspace_ready\", {})) end", 1)
	return os.WriteFile(ownerPath, []byte(code), 0600)
}

func injectOwnerFallback(root string) error {
	path := filepath.Join(root, "src", "launch", "owner.lua")
	contents, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	anchor := "                    spawn_controller(resume)"
	if strings.Count(string(contents), anchor) != 1 {
		return fmt.Errorf("retained owner fallback injection point changed")
	}
	code := strings.Replace(string(contents), anchor,
		"                    if resume and replacement_failures == 0 then resume.version = 2 end\n"+anchor, 1)
	return os.WriteFile(path, []byte(code), 0600)
}

func run() error {
	if len(os.Args) != 2 {
		return fmt.Errorf("usage: retained_owner RUNTIME")
	}
	runtime, err := filepath.Abs(os.Args[1])
	if err != nil {
		return err
	}
	root, err := os.MkdirTemp("", "bee-retained-owner-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
	if err := os.CopyFS(filepath.Join(root, "src"), os.DirFS("src")); err != nil {
		return err
	}
	if err := os.CopyFS(filepath.Join(root, "modules"), os.DirFS("modules")); err != nil {
		return err
	}
	localModules, err := os.ReadFile(".wippy.yaml")
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(root, ".wippy.yaml"), localModules, 0600); err != nil {
		return err
	}
	if err := writeProbe(root); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Join(root, ".wippy"), 0700); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(root, "wippy.lock"), []byte("directories:\n  modules: .wippy\n  src: ./src\n"), 0600); err != nil {
		return err
	}
	manifest, err := os.ReadFile("wippy.yaml")
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(root, "wippy.yaml"), manifest, 0600); err != nil {
		return err
	}
	if err := boot(runtime, root); err != nil {
		return fmt.Errorf("retained owner source: %w", err)
	}
	admission, err := desktopAdmission(root)
	if err != nil {
		return err
	}
	if err := boot(runtime, root, filepath.Join(root, ".wippy.yaml"), admission); err != nil {
		return fmt.Errorf("retained owner with desktop admission: %w", err)
	}
	// The cancellation probe is intentionally source-only; test commands are
	// not part of the shipped portable deployment.
	if err := stop(runtime, root); err != nil {
		return fmt.Errorf("retained owner source: %w", err)
	}
	if err := injectOwnerFallback(root); err != nil {
		return err
	}
	if err := stop(runtime, root); err != nil {
		return fmt.Errorf("retained owner incompatible checkpoint fallback: %w", err)
	}
	deployment, err := filepath.Abs(filepath.Join("dist", "portable-deployment"))
	if err != nil {
		return err
	}
	info, err := os.Stat(deployment)
	if err != nil {
		return fmt.Errorf("portable deployment is unavailable: %w", err)
	}
	if !info.IsDir() {
		return fmt.Errorf("portable deployment is not a directory: %s", deployment)
	}
	if _, err := os.Stat(filepath.Join(deployment, "src")); err == nil {
		return fmt.Errorf("portable deployment retains source: %s", deployment)
	} else if !os.IsNotExist(err) {
		return err
	}
	packed, err := os.MkdirTemp("", "bee-retained-owner-portable-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(packed)
	if err := os.CopyFS(packed, os.DirFS(deployment)); err != nil {
		return fmt.Errorf("copy portable deployment: %w", err)
	}
	if err := boot(runtime, packed); err != nil {
		return fmt.Errorf("retained owner portable deployment: %w", err)
	}
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println("Retained owner: definition replacement and incompatible checkpoint fallback keep the workspace live; source and packed owner boot")
}
