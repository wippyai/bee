// SPDX-License-Identifier: MIT
package main

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

// Catalog is the declared production registry graph under src/.
type Catalog struct {
	Root       string
	Src        string
	Entries    map[string]Entry
	Locations  map[string][]string
	IndexFiles map[string]string
}

// Entry is one registry identity loaded from an _index.yaml document.
type Entry struct {
	Name      string            `yaml:"name"`
	Kind      string            `yaml:"kind"`
	Source    string            `yaml:"source"`
	Modules   []string          `yaml:"modules"`
	Imports   map[string]string `yaml:"imports"`
	Meta      Meta              `yaml:"meta"`
	Security  *Security         `yaml:"security"`
	Policy    *Policy           `yaml:"policy"`
	Bindings  []Binding         `yaml:"bindings"`
	Lifecycle *Lifecycle        `yaml:"lifecycle"`
	File      string            `yaml:"file"`
	Data      map[string]any    `yaml:"data"`
}

// Meta is registry metadata used by admission and launch checks.
type Meta struct {
	Type        string           `yaml:"type"`
	Command     *Command         `yaml:"command"`
	Application *ApplicationMeta `yaml:"application"`
}

// ApplicationMeta is the public application envelope.
type ApplicationMeta struct {
	APIVersion     int    `yaml:"api_version"`
	Revision       any    `yaml:"revision"`
	InstancePolicy string `yaml:"instance_policy"`
}

// Command is a public launch command on a core process.
type Command struct {
	Name     string   `yaml:"name"`
	Security Security `yaml:"security"`
}

// Security lists attached policies.
type Security struct {
	Policies []string `yaml:"policies"`
}

// Policy is a security.policy body. Resources is a string or a list.
type Policy struct {
	Effect    string   `yaml:"effect"`
	Actions   []string `yaml:"actions"`
	Resources any      `yaml:"resources"`
}

// Binding is one host admission row.
type Binding struct {
	DefinitionID string   `yaml:"definition_id"`
	Policies     []string `yaml:"policies"`
	CatalogRead  bool     `yaml:"catalog_read"`
}

// Lifecycle is process start configuration.
type Lifecycle struct {
	AutoStart bool `yaml:"auto_start"`
}

type indexDocument struct {
	Namespace string  `yaml:"namespace"`
	Entries   []Entry `yaml:"entries"`
}

type wippyLock struct {
	Directories struct {
		Src string `yaml:"src"`
	} `yaml:"directories"`
	Modules any `yaml:"modules"`
}

type wippyConfig struct {
	Workspace struct {
		Replacements any `yaml:"replacements"`
	} `yaml:"workspace"`
}

func (e Entry) hasModules() bool {
	return len(e.Modules) > 0
}

func (e Entry) hasSecurity() bool {
	return e.Security != nil
}

func (e Entry) autoStart() bool {
	return e.Lifecycle != nil && e.Lifecycle.AutoStart
}

func (e Entry) containsModule(name string) bool {
	for _, module := range e.Modules {
		if module == name {
			return true
		}
	}
	return false
}

func (p *Policy) resourceList() []string {
	if p == nil {
		return nil
	}
	return stringList(p.Resources)
}

func (p *Policy) containsResource(id string) bool {
	for _, resource := range p.resourceList() {
		if resource == id {
			return true
		}
	}
	return false
}

func (c *Catalog) require(id string) (Entry, error) {
	entry, ok := c.Entries[id]
	if !ok {
		return Entry{}, fmt.Errorf("missing registry identity %s", id)
	}
	return entry, nil
}

func (c *Catalog) applications() map[string]struct{} {
	out := map[string]struct{}{}
	for id, entry := range c.Entries {
		if entry.Meta.Type == "bee.application" {
			out[id] = struct{}{}
		}
	}
	return out
}

func (c *Catalog) clone() *Catalog {
	out := &Catalog{
		Root:       c.Root,
		Src:        c.Src,
		Entries:    make(map[string]Entry, len(c.Entries)),
		Locations:  make(map[string][]string, len(c.Locations)),
		IndexFiles: make(map[string]string, len(c.IndexFiles)),
	}
	for id, entry := range c.Entries {
		out.Entries[id] = cloneEntry(entry)
	}
	for id, parts := range c.Locations {
		out.Locations[id] = append([]string(nil), parts...)
	}
	for id, path := range c.IndexFiles {
		out.IndexFiles[id] = path
	}
	return out
}

func cloneEntry(entry Entry) Entry {
	entry.Modules = append([]string(nil), entry.Modules...)
	if entry.Imports != nil {
		imports := make(map[string]string, len(entry.Imports))
		for name, target := range entry.Imports {
			imports[name] = target
		}
		entry.Imports = imports
	}
	if entry.Security != nil {
		security := *entry.Security
		security.Policies = append([]string(nil), security.Policies...)
		entry.Security = &security
	}
	if entry.Policy != nil {
		policy := *entry.Policy
		policy.Actions = append([]string(nil), policy.Actions...)
		policy.Resources = cloneValue(policy.Resources)
		entry.Policy = &policy
	}
	if entry.Bindings != nil {
		bindings := make([]Binding, len(entry.Bindings))
		for i, binding := range entry.Bindings {
			binding.Policies = append([]string(nil), binding.Policies...)
			bindings[i] = binding
		}
		entry.Bindings = bindings
	}
	if entry.Lifecycle != nil {
		lifecycle := *entry.Lifecycle
		entry.Lifecycle = &lifecycle
	}
	if entry.Data != nil {
		data := make(map[string]any, len(entry.Data))
		for key, value := range entry.Data {
			data[key] = cloneValue(value)
		}
		entry.Data = data
	}
	if entry.Meta.Command != nil {
		command := *entry.Meta.Command
		command.Security.Policies = append([]string(nil), command.Security.Policies...)
		entry.Meta.Command = &command
	}
	if entry.Meta.Application != nil {
		application := *entry.Meta.Application
		entry.Meta.Application = &application
	}
	return entry
}

func cloneValue(value any) any {
	switch typed := value.(type) {
	case []any:
		out := make([]any, len(typed))
		for i, item := range typed {
			out[i] = cloneValue(item)
		}
		return out
	case []string:
		return append([]string(nil), typed...)
	case map[string]any:
		out := make(map[string]any, len(typed))
		for key, item := range typed {
			out[key] = cloneValue(item)
		}
		return out
	default:
		return value
	}
}

func loadYAML(path string, dest any) error {
	body, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	if err := yaml.Unmarshal(body, dest); err != nil {
		return fmt.Errorf("%s: %w", path, err)
	}
	return nil
}

func LoadCatalog(root string) (*Catalog, error) {
	root, err := filepath.Abs(root)
	if err != nil {
		return nil, err
	}
	src := filepath.Join(root, "src")
	catalog := &Catalog{
		Root:       root,
		Src:        src,
		Entries:    map[string]Entry{},
		Locations:  map[string][]string{},
		IndexFiles: map[string]string{},
	}
	err = filepath.WalkDir(src, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if d.IsDir() || d.Name() != "_index.yaml" {
			return nil
		}
		var document indexDocument
		if err := loadYAML(path, &document); err != nil {
			return err
		}
		if document.Namespace == "" {
			return fmt.Errorf("%s: missing namespace", path)
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		parts := strings.Split(filepath.ToSlash(rel), "/")
		for _, entry := range document.Entries {
			if entry.Name == "" {
				return fmt.Errorf("%s: entry missing name", path)
			}
			identity := document.Namespace + ":" + entry.Name
			if _, exists := catalog.Entries[identity]; exists {
				return fmt.Errorf("Duplicate registry identity %s", identity)
			}
			catalog.Entries[identity] = entry
			catalog.Locations[identity] = parts
			catalog.IndexFiles[identity] = path
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return catalog, nil
}

func stringList(value any) []string {
	switch typed := value.(type) {
	case nil:
		return nil
	case string:
		return []string{typed}
	case []string:
		return append([]string(nil), typed...)
	case []any:
		out := make([]string, 0, len(typed))
		for _, item := range typed {
			out = append(out, fmt.Sprint(item))
		}
		return out
	default:
		return []string{fmt.Sprint(typed)}
	}
}

func stringSet(values ...string) map[string]struct{} {
	out := make(map[string]struct{}, len(values))
	for _, value := range values {
		out[value] = struct{}{}
	}
	return out
}

func setOf(values []string) map[string]struct{} {
	return stringSet(values...)
}

func equalSet(got map[string]struct{}, want ...string) bool {
	if len(got) != len(want) {
		return false
	}
	for _, value := range want {
		if _, ok := got[value]; !ok {
			return false
		}
	}
	return true
}

func equalStringSet(got []string, want ...string) bool {
	return equalSet(setOf(got), want...)
}

func containsAll(got []string, want ...string) bool {
	have := setOf(got)
	for _, value := range want {
		if _, ok := have[value]; !ok {
			return false
		}
	}
	return true
}

func hasAnyPrefix(value string, prefixes ...string) bool {
	for _, prefix := range prefixes {
		if strings.HasPrefix(value, prefix) {
			return true
		}
	}
	return false
}

func firstPart(parts []string) string {
	if len(parts) == 0 {
		return ""
	}
	return parts[0]
}

func secondPart(parts []string) string {
	if len(parts) < 2 {
		return ""
	}
	return parts[1]
}

func prefix2(parts []string) [2]string {
	var out [2]string
	if len(parts) > 0 {
		out[0] = parts[0]
	}
	if len(parts) > 1 {
		out[1] = parts[1]
	}
	return out
}

func containedIn(path, root string) bool {
	rel, err := filepath.Rel(root, path)
	if err != nil {
		return false
	}
	rel = filepath.ToSlash(rel)
	return rel != ".." && !strings.HasPrefix(rel, "../")
}

func resolvePath(path string) (string, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	if resolved, err := filepath.EvalSymlinks(abs); err == nil {
		return resolved, nil
	}
	return abs, nil
}

func truthy(value any) bool {
	if value == nil {
		return false
	}
	switch typed := value.(type) {
	case bool:
		return typed
	case string:
		return typed != ""
	case int:
		return typed != 0
	case int64:
		return typed != 0
	case uint64:
		return typed != 0
	case float64:
		return typed != 0
	case []any:
		return len(typed) > 0
	case []string:
		return len(typed) > 0
	case map[string]any:
		return len(typed) > 0
	default:
		return true
	}
}

func slicesEqual(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func resourcesEqual(got any, want any) bool {
	gotList, gotString := resourceAs(got)
	wantList, wantString := resourceAs(want)
	if gotString != nil || wantString != nil {
		if gotString == nil || wantString == nil {
			return false
		}
		return *gotString == *wantString
	}
	return slicesEqual(gotList, wantList)
}

func resourceAs(value any) ([]string, *string) {
	switch typed := value.(type) {
	case string:
		return nil, &typed
	case []string, []any, nil:
		return stringList(value), nil
	default:
		text := fmt.Sprint(typed)
		return nil, &text
	}
}

func bindingByID(bindings []Binding, id string) (Binding, bool) {
	for _, binding := range bindings {
		if binding.DefinitionID == id {
			return binding, true
		}
	}
	return Binding{}, false
}
