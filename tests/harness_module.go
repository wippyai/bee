// SPDX-License-Identifier: MIT
// Behavioral acceptance for the standalone harness composition. The fixture
// stages the harness' declared imports, boots it from source and from a pack,
// and proves that an empty host catalog refuses a request before effects.
package main

import (
	"context"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	"gopkg.in/yaml.v3"
)

type indexFile struct {
	Version   string                   `yaml:"version"`
	Namespace string                   `yaml:"namespace"`
	Entries   []map[string]interface{} `yaml:"entries"`
}

type entrySource struct {
	namespace string
	entry     map[string]interface{}
	indexDir  string
}

func runCommand(ctx context.Context, directory, runtime string, env []string, args ...string) ([]byte, error) {
	command := exec.CommandContext(ctx, runtime, args...)
	command.Dir = directory
	command.Env = append(os.Environ(), env...)
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Cancel = func() error {
		if command.Process == nil || command.Process.Pid <= 0 {
			return nil
		}
		return syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
	}
	command.WaitDelay = 3 * time.Second
	return command.CombinedOutput()
}

func walkIndexes(root string) (map[string]entrySource, error) {
	entries := make(map[string]entrySource)
	err := filepath.WalkDir(filepath.Join(root, "src"), func(path string, item fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if item.IsDir() || item.Name() != "_index.yaml" {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return fmt.Errorf("read %s: %w", path, err)
		}
		var document indexFile
		if err := yaml.Unmarshal(data, &document); err != nil {
			return fmt.Errorf("decode %s: %w", path, err)
		}
		if document.Namespace == "" {
			return fmt.Errorf("%s has no namespace", path)
		}
		for _, entry := range document.Entries {
			name, ok := entry["name"].(string)
			if !ok || name == "" {
				return fmt.Errorf("%s has an entry without a name", path)
			}
			identity := document.Namespace + ":" + name
			if _, exists := entries[identity]; exists {
				return fmt.Errorf("duplicate registry entry %s", identity)
			}
			entries[identity] = entrySource{namespace: document.Namespace, entry: entry, indexDir: filepath.Dir(path)}
		}
		return nil
	})
	return entries, err
}

func stringImports(value interface{}) (map[string]string, error) {
	if value == nil {
		return nil, nil
	}
	imports, ok := value.(map[string]interface{})
	if !ok {
		return nil, fmt.Errorf("imports must be a map")
	}
	result := make(map[string]string, len(imports))
	for name, raw := range imports {
		identity, ok := raw.(string)
		if !ok || identity == "" {
			return nil, fmt.Errorf("import %s is not an identity", name)
		}
		result[name] = identity
	}
	return result, nil
}

func isHarnessNamespace(namespace string) bool {
	return namespace == "bee.harness" || strings.HasPrefix(namespace, "bee.harness.")
}

func copyDeclaredFile(destination, indexDir, value string) error {
	if !strings.HasPrefix(value, "file://") {
		return nil
	}
	relative := strings.TrimPrefix(value, "file://")
	source := filepath.Join(indexDir, filepath.FromSlash(relative))
	data, err := os.ReadFile(source)
	if err != nil {
		return fmt.Errorf("read declared file %s: %w", source, err)
	}
	if err := os.MkdirAll(filepath.Dir(destination), 0700); err != nil {
		return err
	}
	if err := os.WriteFile(destination, data, 0600); err != nil {
		return fmt.Errorf("write declared file %s: %w", destination, err)
	}
	return nil
}

func stage(root string, broken bool) (string, error) {
	entries, err := walkIndexes(root)
	if err != nil {
		return "", err
	}
	selected := make(map[string]bool)
	queue := make([]string, 0)
	for identity, item := range entries {
		if isHarnessNamespace(item.namespace) {
			queue = append(queue, identity)
		}
	}
	sort.Strings(queue)
	for len(queue) > 0 {
		identity := queue[0]
		queue = queue[1:]
		if selected[identity] {
			continue
		}
		item, exists := entries[identity]
		if !exists {
			return "", fmt.Errorf("declared import %s is missing", identity)
		}
		selected[identity] = true
		imports, err := stringImports(item.entry["imports"])
		if err != nil {
			return "", fmt.Errorf("%s: %w", identity, err)
		}
		for _, imported := range imports {
			queue = append(queue, imported)
		}
	}

	folder, err := os.MkdirTemp("", "bee-harness-module-")
	if err != nil {
		return "", fmt.Errorf("create staging directory: %w", err)
	}
	staged := false
	defer func() {
		if !staged {
			os.RemoveAll(folder)
		}
	}()
	grouped := make(map[string][]map[string]interface{})
	identities := make([]string, 0, len(selected))
	for identity := range selected {
		identities = append(identities, identity)
	}
	sort.Strings(identities)
	for _, identity := range identities {
		item := entries[identity]
		entry := item.entry
		if broken && identity == "bee.harness:process_host" {
			entry = make(map[string]interface{}, len(item.entry)+1)
			for key, value := range item.entry {
				entry[key] = value
			}
			entry["targets"] = []interface{}{map[string]interface{}{"entry": "bee.harness:missing_ref", "path": ".host_ref"}}
		}
		grouped[item.namespace] = append(grouped[item.namespace], entry)
		target := filepath.Join(folder, "src", item.namespace)
		for _, field := range []string{"source", "readme"} {
			value, ok := entry[field].(string)
			if !ok || !strings.HasPrefix(value, "file://") {
				continue
			}
			if err := copyDeclaredFile(filepath.Join(target, filepath.FromSlash(strings.TrimPrefix(value, "file://"))), item.indexDir, value); err != nil {
				return "", err
			}
		}
	}
	namespaces := make([]string, 0, len(grouped))
	for namespace := range grouped {
		namespaces = append(namespaces, namespace)
	}
	sort.Strings(namespaces)
	for _, namespace := range namespaces {
		document := indexFile{Version: "1.0", Namespace: namespace, Entries: grouped[namespace]}
		data, err := yaml.Marshal(document)
		if err != nil {
			return "", fmt.Errorf("encode %s: %w", namespace, err)
		}
		path := filepath.Join(folder, "src", namespace, "_index.yaml")
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			return "", err
		}
		if err := os.WriteFile(path, data, 0600); err != nil {
			return "", fmt.Errorf("write %s: %w", path, err)
		}
	}
	if err := os.CopyFS(filepath.Join(folder, "src", "host"), os.DirFS(filepath.Join(root, "tests", "modules", "harness", "src"))); err != nil {
		return "", fmt.Errorf("stage host fixture: %w", err)
	}
	if err := os.WriteFile(filepath.Join(folder, "wippy.lock"), []byte("directories:\n  src: ./src\n"), 0600); err != nil {
		return "", err
	}
	if err := os.WriteFile(filepath.Join(folder, ".wippy.yaml"), []byte("version: '1.0'\nshutdown:\n  timeout: 2s\n"), 0600); err != nil {
		return "", err
	}
	staged = true
	return folder, nil
}

func databaseEnvironment(folder string) []string {
	names := []string{"workspace", "threads", "approvals", "resources", "credentials", "placement", "gateway", "node", "governance"}
	environment := make([]string, 0, len(names))
	for _, name := range names {
		environment = append(environment, "BEE_"+strings.ToUpper(name)+"_DB="+filepath.Join(folder, name+".db"))
	}
	return environment
}

func runFixture(runtime, folder string, env []string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	output, err := runCommand(ctx, folder, runtime, env, args...)
	if err != nil {
		return string(output), fmt.Errorf("%v failed: %w\n%s", args, err, output)
	}
	return string(output), nil
}

func verifyComposition(runtime, root string, broken bool) error {
	folder, err := stage(root, broken)
	if err != nil {
		return err
	}
	defer os.RemoveAll(folder)
	env := databaseEnvironment(folder)
	if _, err := runFixture(runtime, folder, env, "lint"); err != nil {
		return fmt.Errorf("source lint: %w", err)
	}
	output, err := runFixture(runtime, folder, env, "run", "harness-isolation")
	if err != nil {
		return fmt.Errorf("source boot: %w", err)
	}
	marker := "linked host; request refused before effects"
	if broken {
		marker = "unlinked host refused before effects"
	}
	if !strings.Contains(output, marker) {
		return fmt.Errorf("source boot omitted %q\n%s", marker, output)
	}

	pack := filepath.Join(folder, "harness.wapp")
	if _, err := runFixture(runtime, folder, env, "pack", pack); err != nil {
		return fmt.Errorf("pack: %w", err)
	}
	packed, err := os.MkdirTemp("", "bee-harness-packed-")
	if err != nil {
		return fmt.Errorf("create packed directory: %w", err)
	}
	defer os.RemoveAll(packed)
	data, err := os.ReadFile(pack)
	if err != nil {
		return fmt.Errorf("read pack: %w", err)
	}
	if err := os.WriteFile(filepath.Join(packed, "harness.wapp"), data, 0600); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(packed, "wippy.lock"), []byte("directories:\n  src: ./harness.wapp\nmodules: []\n"), 0600); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(packed, ".wippy.yaml"), []byte("version: '1.0'\nshutdown:\n  timeout: 2s\n"), 0600); err != nil {
		return err
	}
	packedEnv := databaseEnvironment(packed)
	output, err = runFixture(runtime, packed, packedEnv, "lint")
	if err != nil {
		return fmt.Errorf("packed lint: %w", err)
	}
	output, err = runFixture(runtime, packed, packedEnv, "run", filepath.Join(packed, "harness.wapp"), "harness-isolation")
	if err != nil {
		return fmt.Errorf("packed boot: %w", err)
	}
	if !strings.Contains(output, marker) {
		return fmt.Errorf("packed boot omitted %q\n%s", marker, output)
	}
	return nil
}

func main() {
	root := ".."
	runtime := ".wippy/bin/bee-wippy"
	for index := 1; index < len(os.Args); index++ {
		switch os.Args[index] {
		case "-root":
			if index+1 >= len(os.Args) {
				panic("-root needs a value")
			}
			root = os.Args[index+1]
			index++
		case "-runtime":
			if index+1 >= len(os.Args) {
				panic("-runtime needs a value")
			}
			runtime = os.Args[index+1]
			index++
		default:
			panic("usage: harness_module [-root ROOT] [-runtime RUNTIME]")
		}
	}
	root, err := filepath.Abs(root)
	if err != nil {
		panic(err)
	}
	runtime, err = filepath.Abs(runtime)
	if err != nil {
		panic(err)
	}
	if _, err := os.Stat(runtime); err != nil {
		panic(fmt.Sprintf("runtime %s: %v", runtime, err))
	}
	for _, broken := range []bool{false, true} {
		if err := verifyComposition(runtime, root, broken); err != nil {
			panic(err)
		}
	}
	fmt.Println("Harness behavioral composition: source and pack boot, empty catalog, linked request refusal, and unlinked host refusal before effects")
}
