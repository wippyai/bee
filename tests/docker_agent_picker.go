// SPDX-License-Identifier: MIT
// Real Docker Agent picker and PTY acceptance. The fixture uses the production
// broker, picker, harness window and Docker placement; only the driver and
// registry declarations are fixture-owned.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"

	"gopkg.in/yaml.v3"
)

type fixtureIndex struct {
	Version   string                   `yaml:"version"`
	Namespace string                   `yaml:"namespace"`
	Entries   []map[string]interface{} `yaml:"entries"`
}

func copyTree(dst, src string) error { return os.CopyFS(dst, os.DirFS(src)) }

func runCommand(ctx context.Context, dir, runtime string, env []string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, runtime, args...)
	cmd.Dir, cmd.Env = dir, append(os.Environ(), env...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return nil
		}
		return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
	cmd.WaitDelay = 3 * time.Second
	return cmd.CombinedOutput()
}

func dockerContainers(socket, attemptID string) ([]map[string]interface{}, error) {
	return dockerContainersWithLabels(socket, map[string]string{"bee.attempt_id": attemptID})
}

func dockerContainersWithLabels(socket string, labels map[string]string) ([]map[string]interface{}, error) {
	transport := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", socket)
	}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 10 * time.Second}
	labelFilters := make([]string, 0, len(labels))
	for key, value := range labels {
		labelFilters = append(labelFilters, key+"="+value)
	}
	filters, err := json.Marshal(map[string][]string{"label": labelFilters})
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequest("GET", "http://docker/containers/json", nil)
	if err != nil {
		return nil, err
	}
	query := req.URL.Query()
	query.Set("all", "true")
	query.Set("filters", string(filters))
	req.URL.RawQuery = query.Encode()
	response, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("Docker list returned HTTP %d", response.StatusCode)
	}
	var containers []map[string]interface{}
	if err := json.NewDecoder(response.Body).Decode(&containers); err != nil {
		return nil, err
	}
	return containers, nil
}

func removeContainers(socket, attemptID string) error {
	containers, err := dockerContainers(socket, attemptID)
	if err != nil {
		return err
	}
	return removeContainerList(socket, containers)
}

func removeContainerList(socket string, containers []map[string]interface{}) error {
	transport := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", socket)
	}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 10 * time.Second}
	for _, container := range containers {
		id, ok := container["Id"].(string)
		if !ok || len(id) != 64 {
			return fmt.Errorf("refusing cleanup of a container without an exact ID")
		}
		req, requestErr := http.NewRequest("DELETE", "http://docker/containers/"+id+"?force=true", nil)
		if requestErr != nil {
			return requestErr
		}
		response, requestErr := client.Do(req)
		if requestErr != nil {
			return requestErr
		}
		response.Body.Close()
		if response.StatusCode != http.StatusNoContent && response.StatusCode != http.StatusNotFound {
			return fmt.Errorf("Docker cleanup returned HTTP %d", response.StatusCode)
		}
	}
	return nil
}

func removeOwnerContainers(socket, owner, image string) error {
	containers, err := dockerContainersWithLabels(socket, map[string]string{
		"bee.actor_ref":    owner,
		"bee.image_digest": image,
	})
	if err != nil {
		return err
	}
	for _, container := range containers {
		labels, ok := container["Labels"].(map[string]interface{})
		if !ok || labels["bee.actor_ref"] != owner || labels["bee.image_digest"] != image {
			return fmt.Errorf("refusing cleanup of a container without the exact fixture labels")
		}
	}
	return removeContainerList(socket, containers)
}

func fixtureContainers(socket, image, project string) ([]map[string]interface{}, error) {
	containers, err := dockerContainersWithLabels(socket, map[string]string{
		"bee.actor_ref": "wippy.test:runner", "bee.image_digest": image,
	})
	if err != nil {
		return nil, err
	}
	selected := []map[string]interface{}{}
	for _, container := range containers {
		mounts, _ := container["Mounts"].([]interface{})
		for _, raw := range mounts {
			mount, _ := raw.(map[string]interface{})
			if source, _ := mount["Source"].(string); filepath.Clean(source) == filepath.Clean(project) {
				selected = append(selected, container)
				break
			}
		}
	}
	return selected, nil
}

func removeFixtureContainers(socket, image, project string) error {
	containers, err := fixtureContainers(socket, image, project)
	if err != nil {
		return err
	}
	return removeContainerList(socket, containers)
}

func envFor(dir string) []string {
	names := []string{"workspace", "threads", "approvals", "resources", "credentials", "placement", "gateway", "node", "governance"}
	env := []string{"HOME=" + filepath.Join(dir, "home"), "XDG_CONFIG_HOME=" + filepath.Join(dir, "config"), "XDG_DATA_HOME=" + filepath.Join(dir, "data"), "XDG_STATE_HOME=" + filepath.Join(dir, "state")}
	for _, name := range names {
		env = append(env, "BEE_"+strings.ToUpper(name)+"_DB="+filepath.Join(dir, name+".db"))
	}
	return env
}

func configureFixture(repo, dir, image string) error {
	fixture := filepath.Join(dir, "src", "tests", "managed_window_app")
	indexPath := filepath.Join(fixture, "_index.yaml")
	indexData, err := os.ReadFile(indexPath)
	if err != nil {
		return err
	}
	var index fixtureIndex
	if err := yaml.Unmarshal(indexData, &index); err != nil {
		return err
	}
	kept := make([]map[string]interface{}, 0, len(index.Entries))
	for _, entry := range index.Entries {
		name, _ := entry["name"].(string)
		if name == "natural_completion_test" || name == "checkpoint_ack_test" || name == "retained_test" || name == "selector_test" {
			continue
		}
		if name == "test" {
			entry["source"] = "file://main.lua"
			entry["method"] = "select"
			security, ok := entry["security"].(map[string]interface{})
			if !ok {
				return fmt.Errorf("selector test has no security declaration")
			}
			policies, ok := security["policies"].([]interface{})
			if !ok {
				return fmt.Errorf("selector test has no policy list")
			}
			security["policies"] = append(policies, "bee.managed_window_fixture:docker_evidence_policy")
		}
		if name == "policy" {
			data, ok := entry["data"].(map[string]interface{})
			if !ok {
				return fmt.Errorf("managed policy has no data")
			}
			data["required_cleanup"] = "contained_tree"
			data["required_exit_observation"] = "independent"
			data["placement_binding"] = "bee.placement.docker:binding"
			data["placement_options"] = map[string]interface{}{
				"image": image, "user": fmt.Sprintf("%d:%d", os.Getuid(), os.Getgid()),
				"network": "none", "memory": 134217728, "nano_cpus": 1000000000,
				"pids_limit": 32, "home_target": "/home/bee",
				"mounts": []map[string]string{{"resource": "project", "target": "/workspace", "access": "read"}},
			}
		}
		if name == "selector_definition" {
			data, ok := entry["data"].(map[string]interface{})
			if !ok {
				return fmt.Errorf("selector definition has no data")
			}
			data["workdir_policy"] = map[string]interface{}{"kind": "declared_resource", "resource_ref": "project"}
		}
		kept = append(kept, entry)
	}
	index.Entries = append(kept,
		map[string]interface{}{"name": "docker_evidence", "kind": "fs.directory", "directory": "evidence", "auto_init": true},
		map[string]interface{}{"name": "docker_evidence_policy", "kind": "security.policy", "policy": map[string]interface{}{"actions": []string{"fs.get"}, "resources": []string{"bee.managed_window_fixture:docker_evidence"}, "effect": "allow"}},
	)
	indexData, err = yaml.Marshal(&index)
	if err != nil {
		return err
	}
	if err := os.WriteFile(indexPath, indexData, 0600); err != nil {
		return err
	}
	mainPath := filepath.Join(fixture, "main.lua")
	mainData, err := os.ReadFile(mainPath)
	if err != nil {
		return err
	}
	mainText := string(mainData)
	preflight := "M.select = function()\n    local plan, refused = admission.resolve(\"bee.managed_window_fixture:selector_definition\", \"window\")\n    if not plan then error(\"Docker Agent picker plan unavailable: \" .. tostring(refused and refused.error and refused.error.message)) end\n"
	updated := strings.Replace(mainText, "M.select = function()\n", preflight, 1)
	if updated == mainText {
		return fmt.Errorf("managed window fixture selection preflight anchor missing")
	}
	mainText = updated
	updated = strings.Replace(mainText, "    assert(live_attempt, \"running native window has no started attempt\")\n", "    assert(live_attempt, \"running native window has no started attempt\")\n    if selected then\n        local evidence = assert(fs.get(\"bee.managed_window_fixture:docker_evidence\"))\n        local marker = assert(evidence:open(\"/attempt_id\", \"w\"))\n        assert(marker:write(live_attempt))\n        marker:close()\n    end\n", 1)
	if updated == mainText {
		return fmt.Errorf("managed window fixture attempt marker anchor missing")
	}
	mainText = updated
	updated = strings.Replace(mainText, `if table.concat(frame.rows):find("MANAGED:hello", 1, true) then saw = true; break end`, `local text = table.concat(frame.rows)
        if text:find("MANAGED:hello", 1, true) and text:find("10 30", 1, true) then saw = true; break end`, 1)
	if updated == mainText {
		return fmt.Errorf("managed window fixture resize assertion anchor missing")
	}
	mainText = updated
	ownerMarker := "    local owner = tostring(process.pid())\n"
	ownerReplacement := ownerMarker + "    if selected then\n        local evidence = assert(fs.get(\"bee.managed_window_fixture:docker_evidence\"))\n        local marker = assert(evidence:open(\"/owner_id\", \"w\"))\n        assert(marker:write(owner))\n        marker:close()\n    end\n"
	updated = strings.Replace(mainText, ownerMarker, ownerReplacement, 1)
	if updated == mainText {
		return fmt.Errorf("managed window fixture owner marker anchor missing")
	}
	mainText = updated
	updated = strings.Replace(mainText, `assert(launched, "Agent picker did not start the selected child")`, `if not launched then
            assert(view:send({type = "resize", width = 120, height = 20}))
            time.sleep("100ms")
            local final = assert(view:snapshot())
            error("Agent picker did not start the selected child: " .. table.concat(final.rows, " | "))
        end`, 1)
	if updated == mainText {
		return fmt.Errorf("managed window fixture launch diagnostic anchor missing")
	}
	mainText = updated
	assertion := `assert(saw, "broker-mounted PTY did not receive input")`
	replacement := `if not saw then
        assert(view:send({type="resize",width=120,height=20}))
        time.sleep("100ms")
        local final=assert(view:snapshot())
        error("Docker Agent launch frame: "..table.concat(final.rows," | "))
    end`
	if !strings.Contains(mainText, assertion) {
		return fmt.Errorf("missing launch diagnostic anchor")
	}
	mainText = strings.Replace(mainText, assertion, replacement, 1)
	return os.WriteFile(mainPath, []byte(mainText), 0600)
}

func configureCodexComponent(dir, image string) error {
	path := filepath.Join(dir, "src", "codex_docker", "_index.yaml")
	raw, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var index fixtureIndex
	if err := yaml.Unmarshal(raw, &index); err != nil {
		return err
	}
	seen := map[string]bool{}
	for _, entry := range index.Entries {
		switch entry["name"] {
		case "image":
			entry["default"] = image
			seen["image"] = true
		case "user":
			entry["default"] = fmt.Sprintf("%d:%d", os.Getuid(), os.Getgid())
			seen["user"] = true
		}
	}
	if !seen["image"] || !seen["user"] {
		return fmt.Errorf("Codex Docker component omitted its host-selected requirements")
	}
	configured, err := yaml.Marshal(index)
	if err != nil {
		return err
	}
	return os.WriteFile(path, configured, 0600)
}

func configureGateway(index string, address string) (string, error) {
	if net.ParseIP(address) == nil || net.ParseIP(address).To4() == nil || !net.ParseIP(address).IsPrivate() {
		return "", fmt.Errorf("gateway interface must be a private IPv4 address")
	}
	if strings.Count(index, "127.0.0.1:0") != 2 {
		return "", fmt.Errorf("gateway listener fixture seam changed")
	}
	index = strings.ReplaceAll(index, "127.0.0.1:0", address+":0")
	old := `(action == "http_client.private_ip" && resource == "127.0.0.1") || (action == "http_client.request" && resource matches "^http://127\\.0\\.0\\.1:[0-9]+/ready$")`
	newPolicy := fmt.Sprintf(`(action == "http_client.private_ip" && resource == %q) || (action == "http_client.request" && resource matches %q)`, address, "^http://"+regexp.QuoteMeta(address)+":[0-9]+/ready$")
	if strings.Count(index, old) != 1 {
		return "", fmt.Errorf("gateway readiness policy fixture seam changed")
	}
	return strings.Replace(index, old, newPolicy, 1), nil
}

const codexContainerProbe = `
const fs=require('fs'),crypto=require('crypto'),http=require('http');
function fail(){process.exit(2)}
if(process.env.HOME!='/home/bee'||process.cwd()!='/workspace')fail();
const auth=fs.readFileSync('/home/bee/.codex/auth.json');
if(crypto.createHash('sha256').update(auth).digest('hex')!==process.argv[1])fail();
fs.writeFileSync('/home/bee/docker-retained-proof','retained');
if(!process.env.BEE_GATEWAY_TOKEN||!process.env.BEE_GATEWAY_HOOK_TOKEN||process.env.BEE_GATEWAY_TOKEN===process.env.BEE_GATEWAY_HOOK_TOKEN)fail();
const args=fs.readFileSync('/proc/1/cmdline','utf8').split('\0');
const raw=args.find(v=>v.startsWith('mcp_servers.bee='));
const found=raw&&raw.match(/url="([^"]+)",bearer_token_env_var="([^"]+)"/);
if(!found||process.env[found[2]]!==process.env.BEE_GATEWAY_TOKEN)fail();
const target=new URL(found[1]);
function call(id,method,params){return new Promise((resolve,reject)=>{const body=JSON.stringify({jsonrpc:'2.0',id,method,params});const req=http.request(target,{method:'POST',headers:{Authorization:'Bearer '+process.env.BEE_GATEWAY_TOKEN,'Content-Type':'application/json','Content-Length':Buffer.byteLength(body)}},res=>{let out='';res.on('data',v=>out+=v);res.on('end',()=>{try{const parsed=JSON.parse(out);if(res.statusCode!==200||parsed.jsonrpc!=='2.0'||parsed.error)fail();resolve(parsed.result)}catch(e){reject(e)}})});req.on('error',reject);req.end(body)})}
(async()=>{await call(1,'initialize',{protocolVersion:'2025-06-18',capabilities:{},clientInfo:{name:'bee-codex-docker-proof',version:'0'}});const listed=await call(2,'tools/list',{});const names=listed.tools.map(v=>v.name).sort().join(',');if(names!=='thread_message,thread_read,thread_wait')fail();console.log('BEE_CODEX_DOCKER_PROBE_OK')})().catch(fail);
`

func dockerExecProbe(ctx context.Context, socket, containerID, authDigest string) error {
	probe := exec.CommandContext(ctx, "docker", "exec", containerID, "node", "-e", codexContainerProbe, authDigest)
	probe.Env = append(os.Environ(), "DOCKER_HOST=unix://"+socket)
	output, err := probe.CombinedOutput()
	if err != nil || strings.TrimSpace(string(output)) != "BEE_CODEX_DOCKER_PROBE_OK" {
		return fmt.Errorf("Codex container identity, credential and MCP probe failed: %v: %s", err, output)
	}
	size := exec.CommandContext(ctx, "docker", "exec", containerID, "sh", "-c", "stty size < /proc/1/fd/0")
	size.Env = append(os.Environ(), "DOCKER_HOST=unix://"+socket)
	sizeOutput, err := size.CombinedOutput()
	if err != nil || strings.TrimSpace(string(sizeOutput)) != "27 91" {
		return fmt.Errorf("Codex container PTY resize was not observed: %v: %s", err, sizeOutput)
	}
	return nil
}

func findRetainedProof(root string) error {
	found := 0
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.Name() != "docker-retained-proof" {
			return nil
		}
		data, readErr := os.ReadFile(path)
		if readErr != nil || string(data) != "retained" {
			return fmt.Errorf("retained HOME marker is invalid: %v", readErr)
		}
		found++
		return nil
	})
	if err != nil {
		return err
	}
	if found != 1 {
		return fmt.Errorf("expected one retained private HOME marker, found %d", found)
	}
	return nil
}

func runCodexPicker(ctx context.Context, dir, runtime string, env []string, socket, image, authDigest string) ([]byte, error) {
	command := exec.CommandContext(ctx, runtime, "test", "--host", "bee:terminal")
	command.Dir, command.Env = dir, append(os.Environ(), env...)
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Cancel = func() error {
		if command.Process == nil {
			return nil
		}
		return syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
	}
	command.WaitDelay = 3 * time.Second
	var output bytes.Buffer
	command.Stdout, command.Stderr = &output, &output
	if err := command.Start(); err != nil {
		return nil, err
	}
	done := make(chan error, 1)
	go func() { done <- command.Wait() }()
	ready := filepath.Join(dir, "evidence", "ready")
	deadline := time.NewTimer(50 * time.Second)
	defer deadline.Stop()
	for {
		if _, err := os.Stat(ready); err == nil {
			break
		}
		select {
		case err := <-done:
			return output.Bytes(), fmt.Errorf("Codex Docker picker exited before inspection: %w", err)
		case <-deadline.C:
			return output.Bytes(), fmt.Errorf("Codex Docker picker did not expose a running container")
		case <-time.After(50 * time.Millisecond):
		}
	}
	containers, err := fixtureContainers(socket, image, filepath.Join(dir, "project"))
	if err != nil || len(containers) != 1 {
		return output.Bytes(), fmt.Errorf("expected one exact test-owner/image container, got %d: %v", len(containers), err)
	}
	containerID, _ := containers[0]["Id"].(string)
	labels, _ := containers[0]["Labels"].(map[string]interface{})
	attemptID, _ := labels["bee.attempt_id"].(string)
	if len(containerID) != 64 || attemptID == "" {
		return output.Bytes(), fmt.Errorf("Codex Docker container omitted exact identities")
	}
	if err := os.WriteFile(filepath.Join(dir, "evidence", "attempt_id"), []byte(attemptID), 0600); err != nil {
		return output.Bytes(), err
	}
	probeCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	err = dockerExecProbe(probeCtx, socket, containerID, authDigest)
	cancel()
	if err != nil {
		return output.Bytes(), err
	}
	if err := os.WriteFile(filepath.Join(dir, "evidence", "continue"), []byte("continue"), 0600); err != nil {
		return output.Bytes(), err
	}
	select {
	case err := <-done:
		return output.Bytes(), err
	case <-ctx.Done():
		return output.Bytes(), ctx.Err()
	}
}

func run() error {
	runtime := flag.String("runtime", "", "composed Bee runtime")
	dockerSource := flag.String("docker-source", "", "userspace Docker client package")
	image := flag.String("image", "", "already-local immutable Docker image")
	socket := flag.String("socket", "/var/run/docker.sock", "Docker Unix socket")
	root := flag.String("root", ".", "Bee repository root")
	codexComponent := flag.Bool("codex-component", false, "exercise the real optional Codex Docker component")
	gatewayInterface := flag.String("interface", "", "private Docker-reachable gateway interface")
	flag.Parse()
	if *runtime == "" || *dockerSource == "" || !strings.HasPrefix(*image, "sha256:") || len(*image) != 71 || os.Getuid() == 0 || os.Getgid() == 0 || (*codexComponent && *gatewayInterface == "") {
		return fmt.Errorf("runtime, Docker client, immutable image and non-root user required")
	}
	repo, err := filepath.Abs(*root)
	if err != nil {
		return err
	}
	runtimePath, err := filepath.Abs(*runtime)
	if err != nil {
		return err
	}
	if _, err := os.Stat(runtimePath); err != nil {
		return err
	}
	fixtureParent, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	dir, err := os.MkdirTemp(fixtureParent, ".bee-docker-agent-picker-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	defer func() {
		if *codexComponent {
			if cleanupErr := removeFixtureContainers(filepath.Clean(*socket), *image, filepath.Join(dir, "project")); cleanupErr != nil {
				fmt.Fprintf(os.Stderr, "Codex Docker fixture cleanup failed: %v\n", cleanupErr)
			}
			return
		}
		ownerData, readErr := os.ReadFile(filepath.Join(dir, "evidence", "owner_id"))
		owner := strings.TrimSpace(string(ownerData))
		if readErr == nil && owner != "" {
			if cleanupErr := removeOwnerContainers(filepath.Clean(*socket), owner, *image); cleanupErr != nil {
				fmt.Fprintf(os.Stderr, "Docker fixture cleanup failed: %v\n", cleanupErr)
			}
		}
	}()
	if *codexComponent {
		if err := removeFixtureContainers(filepath.Clean(*socket), *image, filepath.Join(dir, "project")); err != nil {
			return fmt.Errorf("remove stale Codex Docker fixture containers: %w", err)
		}
	}
	for _, name := range []string{"home", "config", "data", "state", "project", "evidence"} {
		if err := os.MkdirAll(filepath.Join(dir, name), 0700); err != nil {
			return err
		}
	}
	if err := copyTree(filepath.Join(dir, "src"), filepath.Join(repo, "src")); err != nil {
		return err
	}
	if *codexComponent {
		if err := copyTree(filepath.Join(dir, "src", "tests", "codex_docker_picker"), filepath.Join(repo, "tests", "fixtures", "codex_docker_picker")); err != nil {
			return err
		}
		if err := copyTree(filepath.Join(dir, "src", "codex_docker"), filepath.Join(repo, "modules", "bee-driver-codex-docker", "src")); err != nil {
			return err
		}
		if err := configureCodexComponent(dir, *image); err != nil {
			return err
		}
	} else if err := copyTree(filepath.Join(dir, "src", "tests", "managed_window_app"), filepath.Join(repo, "tests", "fixtures", "managed_window_app")); err != nil {
		return err
	}
	if err := copyTree(filepath.Join(dir, "src", "docker_daemon"), filepath.Join(repo, "modules", "bee-placement-docker-daemon", "src")); err != nil {
		return err
	}
	if err := copyTree(filepath.Join(dir, "src", "docker_client"), *dockerSource); err != nil {
		return err
	}
	if !*codexComponent {
		if err := configureFixture(repo, dir, *image); err != nil {
			return err
		}
	}
	rootIndex, err := os.ReadFile(filepath.Join(dir, "src", "_index.yaml"))
	if err != nil {
		return err
	}
	workspaceRoot := "- name: workspace_root\n  kind: fs.directory\n  directory: .\n  base: project"
	fixtureRoot := "- name: workspace_root\n  kind: fs.directory\n  directory: project\n  base: project"
	rootText := strings.Replace(string(rootIndex), workspaceRoot, fixtureRoot, 1)
	if rootText == string(rootIndex) {
		return fmt.Errorf("workspace root fixture anchor missing")
	}
	updatedIndex := rootText
	if *codexComponent {
		anchor := "bindings: [bee.driver.agy:binding, bee.driver.claude:binding, bee.driver.codex:binding, bee.driver.grok:binding]"
		updatedIndex = strings.Replace(updatedIndex, anchor, strings.TrimSuffix(anchor, "]")+", bee.driver.codex.docker:binding]", 1)
		if updatedIndex == rootText {
			return fmt.Errorf("Codex Docker host activation anchor missing")
		}
		updatedIndex, err = configureGateway(updatedIndex, *gatewayInterface)
		if err != nil {
			return err
		}
	} else {
		anchor := "bindings: [bee.driver.agy:binding, bee.driver.claude:binding, bee.driver.codex:binding, bee.driver.grok:binding]"
		updatedIndex = strings.Replace(rootText, anchor, strings.TrimSuffix(anchor, "]")+", bee.managed_window_fixture:binding]", 1)
		if updatedIndex == rootText {
			return fmt.Errorf("host activation anchor missing")
		}
	}
	updatedIndex = strings.TrimRight(updatedIndex, "\n") + "\n- name: test_dependency\n  kind: ns.dependency\n  component: wippy/test\n  version: 0.4.17\n"
	if err := os.WriteFile(filepath.Join(dir, "src", "_index.yaml"), []byte(updatedIndex), 0600); err != nil {
		return err
	}
	daemonIndex := filepath.Join(dir, "src", "docker_daemon", "_index.yaml")
	daemonData, err := os.ReadFile(daemonIndex)
	if err != nil {
		return err
	}
	selectedSocket := filepath.Clean(*socket)
	daemonText := strings.Replace(string(daemonData), "expression: 'false'", "expression: 'resource == \""+selectedSocket+"\"'", 1)
	if daemonText == string(daemonData) {
		return fmt.Errorf("daemon socket policy anchor missing")
	}
	if err := os.WriteFile(daemonIndex, []byte(daemonText), 0600); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Join(dir, "src", "docker_host"), 0700); err != nil {
		return err
	}
	hostIndex := "version: '1.0'\nnamespace: bee.placement.docker.daemon\nentries:\n- name: daemon_ref\n  kind: registry.entry\n  data: {resource_ref: bee.placement.docker.daemon:fixture_socket}\n- name: fixture_socket\n  kind: registry.entry\n  meta: {type: bee.docker_daemon}\n  data: {socket_path: " + selectedSocket + "}\n"
	if err := os.WriteFile(filepath.Join(dir, "src", "docker_host", "_index.yaml"), []byte(hostIndex), 0600); err != nil {
		return err
	}
	config := "version: '1.0'\nregistry:\n  enable_history: true\n  history_type: sqlite\n  history_path: .wippy/registry.db\ndirectories:\n  modules: .wippy\n  src: ./src\nbee:\n  docker:\n    reference: bee.placement.docker.daemon:daemon_ref\n    host: unix://" + selectedSocket + "\n"
	if err := os.WriteFile(filepath.Join(dir, ".wippy.yaml"), []byte(config), 0600); err != nil {
		return err
	}
	lock, err := os.ReadFile(filepath.Join(repo, "wippy.lock"))
	if err != nil {
		return err
	}
	deps, err := os.ReadFile(filepath.Join(repo, "tests", "dependencies.yaml"))
	if err != nil {
		return err
	}
	lockText := strings.TrimRight(string(lock), "\n") + "\n" + strings.TrimLeft(string(deps), "\n") + "\n"
	if err := os.WriteFile(filepath.Join(dir, "wippy.lock"), []byte(lockText), 0600); err != nil {
		return err
	}
	env := envFor(dir)
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()
	if out, err := runCommand(ctx, dir, runtimePath, env, "install"); err != nil {
		return fmt.Errorf("staged dependency install failed: %w\n%s", err, out)
	}
	if out, err := runCommand(ctx, dir, runtimePath, env, "lint", "--set", "lua.type_system.enabled=true", "--set", "lua.type_system.strict=true"); err != nil {
		return fmt.Errorf("staged lint failed: %w\n%s", err, out)
	}
	if *codexComponent {
		auth := []byte(`{"OPENAI_API_KEY":"sk-fixture-only","auth_mode":"apikey","last_refresh":"2026-09-14T00:00:00Z","tokens":null}`)
		if err := os.MkdirAll(filepath.Join(dir, "home", ".codex"), 0700); err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(dir, "home", ".codex", "auth.json"), auth, 0600); err != nil {
			return err
		}
		digest := fmt.Sprintf("%x", sha256.Sum256(auth))
		out, err := runCodexPicker(ctx, dir, runtimePath, env, selectedSocket, *image, digest)
		if err != nil {
			return fmt.Errorf("real Codex Docker picker acceptance failed: %w\n%s", err, out)
		}
		if err := findRetainedProof(dir); err != nil {
			return err
		}
		attempt, readErr := os.ReadFile(filepath.Join(dir, "evidence", "attempt_id"))
		if readErr != nil {
			return readErr
		}
		containers, listErr := dockerContainers(selectedSocket, strings.TrimSpace(string(attempt)))
		if listErr != nil {
			return listErr
		}
		if len(containers) != 0 {
			return fmt.Errorf("Codex Docker close leaked %d exact-attempt containers", len(containers))
		}
		fmt.Println("PASS: production Agent picker launched the real optional Codex Docker component; PTY input/resize, private retained HOME, credential projection, scoped MCP and exact container removal passed without a model turn")
		return nil
	}
	out, err := runCommand(ctx, dir, runtimePath, env, "test", "--host", "bee:terminal")
	if err != nil {
		return fmt.Errorf("Docker Agent picker acceptance failed: %w\n%s", err, out)
	}
	marker, err := os.ReadFile(filepath.Join(dir, "evidence", "attempt_id"))
	if err != nil || len(marker) == 0 {
		return fmt.Errorf("acceptance omitted the unpredictable attempt label: %v\n%s", err, out)
	}
	attemptID := strings.TrimSpace(string(marker))
	containers, err := dockerContainers(selectedSocket, attemptID)
	if err != nil {
		return err
	}
	if len(containers) != 0 {
		_ = removeContainers(selectedSocket, attemptID)
		return fmt.Errorf("Docker stop/removal leaked %d container(s) for exact attempt label %s", len(containers), attemptID)
	}
	fmt.Println("PASS: production Agent picker selected Docker, real container PTY exchanged input, resize was observed, and exact attempt-label stop/removal left no container")
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
