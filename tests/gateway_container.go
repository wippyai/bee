// SPDX-License-Identifier: MIT
// Real local-container MCP routing; no harness account credentials or mounts.
package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io/fs"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"
)

const containerScript = `
const input = JSON.parse(require('fs').readFileSync(0, 'utf8'));
function check(ok, message) { if (!ok) throw Error(message); }
async function rpc({token=input.token, host, origin, action='container-action', method='initialize', params={}, endpoint='mcp', payload}={}) {
 const headers = {'Content-Type':'application/json'};
 if (token) headers.Authorization = 'Bearer '+token;
 if (host) headers.Host = host;
 if (origin) headers.Origin = origin;
 return await new Promise((resolve,reject)=>{
  const request = require('http').request('http://'+input.address+'/'+endpoint+'/'+action,
   {method:'POST',headers,timeout:5000}, response=>{
    let body='';
    response.setEncoding('utf8');
    response.on('data',chunk=>{body+=chunk;if(body.length>1048576)response.destroy(Error('oversized reply'));});
    response.on('error',reject);
    response.on('end',()=>{try{resolve({status:response.statusCode,headers:response.headers,
     body:(response.headers['content-type']||'').includes('application/json') ? JSON.parse(body) : body});}catch(e){reject(e);}});
   });
  request.on('error',reject);
  request.on('timeout',()=>request.destroy(Error('request timeout')));
  request.end(JSON.stringify(payload ?? {jsonrpc:'2.0',id:1,method,params}));
 });
}
(async()=>{
 const hook = options=>rpc({endpoint:'hook',token:input.hook_token,
  payload:{hook_event_name:'SessionStart',session_id:'container-session',source:'startup'},...options});
 const hookMcp = options=>rpc({endpoint:'hook',action:'container-action/mcp',token:input.hook_token,...options});
 if (input.phase==='revoked') {
  check((await rpc()).status===401,'revoked tool token accepted');
  check((await hook()).status===401,'revoked hook token accepted');
  check((await hookMcp()).status===401,'revoked MCP hook token accepted');
  return;
 }
 check((await rpc()).body.result?.protocolVersion,'initialize failed');
 const tools = (await rpc({method:'tools/list'})).body.result?.tools?.map(t=>t.name).sort();
 check(JSON.stringify(tools)===JSON.stringify(['thread_read','thread_wait']),'scope changed');
 const page = await rpc({method:'tools/call',params:{name:'thread_read',arguments:{cursor:0}}});
 check(page.status===200 && JSON.parse(page.body.result.content[0].text).ok===true,'thread read refused');
 check((await rpc({token:''})).status===401,'missing token accepted');
 check((await rpc({action:'other-action'})).status===403,'cross-action token did not return forbidden');
 check((await rpc({host:'127.0.0.1:1'})).status===403,'foreign host accepted');
 check((await rpc({host:input.address.replace(/:\d+$/,':1')})).status===403,'wrong port accepted');
 check((await rpc({origin:'http://example.invalid'})).status===403,'browser origin accepted');
 check(input.hook_token && input.hook_token!==input.token,'hook credential is not separate');
 check((await rpc({token:input.hook_token})).status===401,'hook credential accepted for tools');
 check((await hook({token:input.token})).status===401,'tool credential accepted for hooks');
 check((await hook({token:''})).status===401,'missing hook credential accepted');
 check((await hook({action:'other-action'})).status===403,'cross-action hook accepted');
 check((await hook({host:'127.0.0.1:1'})).status===403,'foreign hook Host accepted');
 check((await hook({host:input.address.replace(/:\d+$/,':1')})).status===403,'wrong hook port accepted');
 check((await hook({origin:'http://example.invalid'})).status===403,'hook browser origin accepted');
 const first=await hook(), replay=await hook();
 check(first.status===202 && first.body==='' && first.headers['x-bee-event'],'hook was not queued with an empty response');
 check(replay.status===202 && replay.body==='' && replay.headers['x-bee-event']===first.headers['x-bee-event'],'hook replay duplicated its occurrence');
 const hookTools=(await hookMcp({method:'tools/list'})).body.result?.tools?.map(t=>t.name);
 check(JSON.stringify(hookTools)===JSON.stringify(['hook']),'MCP hook endpoint exposes the wrong tool set');
 check((await hookMcp({token:input.token})).status===401,'tool credential accepted for MCP hooks');
 check((await hookMcp({token:''})).status===401,'missing MCP hook credential accepted');
 check((await hookMcp({action:'other-action/mcp'})).status===403,'cross-action MCP hook accepted');
 check((await hookMcp({host:'127.0.0.1:1'})).status===403,'foreign MCP hook Host accepted');
 check((await hookMcp({host:input.address.replace(/:\d+$/,':1')})).status===403,'wrong MCP hook port accepted');
 check((await hookMcp({origin:'http://example.invalid'})).status===403,'MCP hook browser origin accepted');
 const event={method:'tools/call',params:{name:'hook',arguments:{event:'SessionStart',session_id:'container-mcp-session',source:'startup'},
  _meta:{threadId:'container-mcp-session',progressToken:1}}};
 const mcpFirst=await hookMcp(event),mcpReplay=await hookMcp(event);
 const receipt=mcpFirst.body.result?.content?.[0]?.text;
 check(mcpFirst.status===200 && receipt?.startsWith('queued '),'MCP hook was not queued');
 check(mcpReplay.status===200 && mcpReplay.body.result?.content?.[0]?.text===receipt,'MCP hook replay duplicated its occurrence');
})().catch(e=>{console.error(e.message);process.exitCode=1;});
`

func copyTree(from, to string) error {
	return filepath.WalkDir(from, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		relative, err := filepath.Rel(from, path)
		if err != nil {
			return err
		}
		target := filepath.Join(to, relative)
		if entry.IsDir() {
			return os.MkdirAll(target, 0700)
		}
		if !entry.Type().IsRegular() {
			return fmt.Errorf("nonregular fixture source: %s", path)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		return os.WriteFile(target, data, 0600)
	})
}

func run() error {
	runtime := flag.String("runtime", "", "selected Bee runtime")
	address := flag.String("interface", "", "explicit local Docker bridge IPv4 address")
	image := flag.String("image", "", "already installed Node image, full sha256 ID")
	network := flag.String("network", "bridge", "host-selected local Docker network")
	readinessOnly := flag.Bool("readiness-only", false, "prove the default loopback readiness policy without Docker")
	flag.Parse()
	ip := net.ParseIP(*address)
	if *readinessOnly {
		*address = "127.0.0.1"
	}
	if *runtime == "" || (!*readinessOnly && (ip == nil || ip.To4() == nil || !ip.IsPrivate() ||
		!regexp.MustCompile(`^sha256:[a-f0-9]{64}$`).MatchString(*image))) {
		return fmt.Errorf("runtime, private IPv4 interface and immutable local Node image are required")
	}
	root, err := os.MkdirTemp("", "bee-gateway-container-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
	if err := copyTree("src", filepath.Join(root, "src")); err != nil {
		return err
	}
	if err := copyTree("modules", filepath.Join(root, "modules")); err != nil {
		return err
	}
	if err := copyTree("tests/fixtures/gateway_container", filepath.Join(root, "src/container_probe")); err != nil {
		return err
	}
	for _, name := range []string{".wippy.yaml", "wippy.lock"} {
		data, err := os.ReadFile(name)
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(root, name), data, 0600); err != nil {
			return err
		}
	}
	if err := os.MkdirAll(filepath.Join(root, ".wippy"), 0700); err != nil {
		return err
	}
	manifestPath := filepath.Join(root, "src/gateway/host/_index.yaml")
	manifest, err := os.ReadFile(manifestPath)
	if err != nil {
		return err
	}
	changed := strings.ReplaceAll(string(manifest), "127.0.0.1:0", *address+":0")
	if strings.Count(string(manifest), "127.0.0.1:0") != 2 {
		return fmt.Errorf("gateway listener fixture seam changed")
	}
	if err := os.WriteFile(manifestPath, []byte(changed), 0600); err != nil {
		return err
	}
	manifestPath = filepath.Join(root, "modules/gateway/src/security/_index.yaml")
	manifest, err = os.ReadFile(manifestPath)
	if err != nil {
		return err
	}
	changed = string(manifest)
	readinessExpression := func(ip string) string {
		return fmt.Sprintf(`(action == "http_client.private_ip" && resource == %q) || (action == "http_client.request" && resource matches %q)`, ip, "^http://"+regexp.QuoteMeta(ip)+":[0-9]+/ready$")
	}
	if strings.Count(changed, readinessExpression("127.0.0.1")) != 1 {
		return fmt.Errorf("readiness policy fixture seam changed")
	}
	if !*readinessOnly {
		changed = strings.Replace(changed, readinessExpression("127.0.0.1"), readinessExpression(*address), 1)
	}
	if err := os.WriteFile(manifestPath, []byte(changed), 0600); err != nil {
		return err
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	var secret [16]byte
	if _, err := rand.Read(secret[:]); err != nil {
		listener.Close()
		return err
	}
	path := "/" + hex.EncodeToString(secret[:])
	callbackURL := "http://" + listener.Addr().String() + path
	probePath := filepath.Join(root, "src/container_probe/_index.yaml")
	probeManifest, err := os.ReadFile(probePath)
	if err != nil {
		listener.Close()
		return err
	}
	if strings.Count(string(probeManifest), "BEE_CONTAINER_CALLBACK_URL") != 1 {
		listener.Close()
		return fmt.Errorf("callback policy fixture seam changed")
	}
	if err := os.WriteFile(probePath, []byte(strings.Replace(string(probeManifest), "BEE_CONTAINER_CALLBACK_URL", callbackURL, 1)), 0600); err != nil {
		listener.Close()
		return err
	}
	var mu sync.Mutex
	phases := []string{}
	problems := []string{}
	tokens := []string{}
	server := &http.Server{ReadHeaderTimeout: 5 * time.Second}
	server.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" || r.URL.Path != path {
			http.NotFound(w, r)
			return
		}
		var input struct {
			Phase     string `json:"phase"`
			Address   string `json:"address"`
			Token     string `json:"token"`
			HookToken string `json:"hook_token"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16384)).Decode(&input); err != nil {
			http.Error(w, "invalid fixture callback", 400)
			return
		}
		mu.Lock()
		defer mu.Unlock()
		if input.Token == "" || input.HookToken == "" || !strings.HasPrefix(input.Address, *address+":") ||
			(len(phases) == 0 && input.Phase != "active") || (len(phases) == 1 && input.Phase != "revoked") || len(phases) > 1 {
			problems = append(problems, "invalid callback phase or identity")
			http.Error(w, "invalid fixture state", 400)
			return
		}
		tokens = append(tokens, input.Token, input.HookToken)
		if *readinessOnly {
			phases = append(phases, input.Phase)
			w.WriteHeader(200)
			return
		}
		body, _ := json.Marshal(input)
		ctx, cancel := context.WithTimeout(r.Context(), 35*time.Second)
		defer cancel()
		name := "bee-gateway-proof-" + hex.EncodeToString(secret[:]) + "-" + input.Phase
		cmd := exec.CommandContext(ctx, "docker", "run", "--rm", "--pull=never", "--name", name, "--network", *network,
			"--read-only", "--cap-drop=ALL", "--security-opt=no-new-privileges:true", "--pids-limit=64", "--memory=256m", "--cpus=1",
			"--user", fmt.Sprintf("%d:%d", os.Getuid(), os.Getgid()), "-i", *image, "node", "-e", containerScript)
		cmd.Stdin = bytes.NewReader(body)
		output, runError := cmd.CombinedOutput()
		if runError != nil {
			cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 5*time.Second)
			cleanupOutput, cleanupError := exec.CommandContext(cleanupCtx, "docker", "rm", "-f", name).CombinedOutput()
			cleanupCancel()
			if cleanupError != nil {
				problems = append(problems, fmt.Sprintf("container cleanup was not confirmed for %s: %v: %s", name, cleanupError, cleanupOutput))
			}
			detail := strings.ReplaceAll(string(output), input.Token, "[redacted]")
			detail = strings.ReplaceAll(detail, input.HookToken, "[redacted]")
			problems = append(problems, fmt.Sprintf("container %s: %v: %s", input.Phase, runError, detail))
			http.Error(w, "container proof failed", 500)
			return
		}
		phases = append(phases, input.Phase)
		w.WriteHeader(200)
	})
	served := make(chan struct{})
	go func() { defer close(served); _ = server.Serve(listener) }()
	defer func() { _ = server.Close(); <-served }()
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, *runtime, "--console", "run", "gateway-container-probe", "--host", "bee:workers", "--set", "registry.history_path="+filepath.Join(root, "registry.db"))
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Cancel = func() error { return syscall.Kill(-command.Process.Pid, syscall.SIGKILL) }
	command.WaitDelay = 5 * time.Second
	command.Dir = root
	environment := map[string]string{"BEE_CONTAINER_CALLBACK": callbackURL}
	for _, name := range []string{"workspace", "threads", "approvals", "resources", "credentials", "placement", "gateway", "node", "governance", "client"} {
		environment["BEE_"+strings.ToUpper(name)+"_DB"] = filepath.Join(root, name+".db")
	}
	for _, item := range os.Environ() {
		key, _, _ := strings.Cut(item, "=")
		if _, overridden := environment[key]; !overridden {
			command.Env = append(command.Env, item)
		}
	}
	for key, value := range environment {
		command.Env = append(command.Env, key+"="+value)
	}
	lint := exec.CommandContext(ctx, *runtime, "lint")
	lint.Dir, lint.Env = root, command.Env
	if output, err := lint.CombinedOutput(); err != nil {
		return fmt.Errorf("container fixture lint: %v\n%s", err, output)
	}
	output, runError := command.CombinedOutput()
	mu.Lock()
	defer mu.Unlock()
	if runError != nil || len(problems) > 0 || strings.Join(phases, ",") != "active,revoked" {
		detail := string(output)
		for _, token := range tokens {
			detail = strings.ReplaceAll(detail, token, "[redacted]")
		}
		return fmt.Errorf("gateway container proof: runtime=%v phases=%v problems=%v\n%s", runError, phases, problems, detail)
	}
	if *readinessOnly {
		fmt.Println("Default native random-port readiness passed under the narrow fixture policy")
	} else {
		fmt.Println("Container gateway: native random port, scoped MCP read, separate HTTP/MCP hook credentials, hook replay, missing/cross-action/revoked token and wrong Host/port/Origin refusal passed")
	}
	return nil
}
func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
