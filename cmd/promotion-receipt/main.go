// SPDX-License-Identifier: MIT

// Command promotion-receipt records the immutable inputs of a completed Bee
// promotion check. It never installs or stops Bee.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"time"
)

var artifactSuffixes = []string{"", ".LICENSES.txt", ".go.mod", ".go.sum", ".provenance.json", ".runtime-patches.tar.gz"}

type artifact struct {
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
	Bytes  int64  `json:"bytes"`
}

type provider struct {
	Path    string `json:"path"`
	SHA256  string `json:"sha256"`
	Version string `json:"version"`
}

type privateInput struct {
	SHA256  string `json:"sha256,omitempty"`
	Bytes   int64  `json:"bytes,omitempty"`
	Env     string `json:"env,omitempty"`
	Present bool   `json:"present"`
}

type packAudit struct {
	Entries        int `json:"entries"`
	Packs          int `json:"packs"`
	EmbeddedAssets int `json:"embedded_assets"`
}

type invocation struct {
	EntryTarget   string            `json:"entry_target"`
	GateTarget    string            `json:"gate_target"`
	Makefile      artifact          `json:"makefile"`
	Variables     map[string]string `json:"variables"`
	PrivateInputs []string          `json:"private_inputs"`
}

type receipt struct {
	Schema         int                     `json:"schema"`
	Milestone      string                  `json:"milestone"`
	Commit         string                  `json:"commit"`
	CreatedAt      string                  `json:"created_at"`
	Artifacts      []artifact              `json:"artifacts"`
	Runtime        artifact                `json:"runtime"`
	Previous       artifact                `json:"previous"`
	Providers      map[string]provider     `json:"providers"`
	PrivateInputs  map[string]privateInput `json:"private_inputs"`
	BuildManifest  artifact                `json:"build_manifest"`
	BundleManifest artifact                `json:"bundle_manifest"`
	PackAudit      packAudit               `json:"pack_audit"`
	Invocation     invocation              `json:"invocation"`
	Provenance     json.RawMessage         `json:"provenance"`
	PassedGates    []string                `json:"passed_gates"`
	GlobalInstall  struct {
		Performed bool `json:"performed"`
	} `json:"global_install"`
}

func main() {
	var milestone, expectedCommit, binary, runtime, previous, buildManifest, bundleManifest, output, agyModel, builderCommand, beeVersion, beeMode string
	providers := map[string]*string{}
	privateFiles := map[string]*string{}
	var claudeCredentialEnv string
	flag.StringVar(&milestone, "milestone", "", "promotion milestone")
	flag.StringVar(&expectedCommit, "expected-commit", "", "commit captured before the promotion gates")
	flag.StringVar(&binary, "binary", "", "candidate Bee executable")
	flag.StringVar(&runtime, "runtime", "", "exact Wippy runtime used by the gates")
	flag.StringVar(&previous, "previous", "", "rollback Bee executable")
	flag.StringVar(&buildManifest, "build-manifest", "", "pinned source build manifest")
	flag.StringVar(&bundleManifest, "bundle-manifest", "", "generated sealed bundle manifest")
	flag.StringVar(&output, "output", "", "receipt output path")
	flag.StringVar(&agyModel, "agy-model", "", "Agy model used by the live recovery gate")
	flag.StringVar(&builderCommand, "builder-command", "", "builder command selected by the Make invocation")
	flag.StringVar(&beeVersion, "bee-version", "", "optional bundle version override")
	flag.StringVar(&beeMode, "bee-mode", "", "optional bundle mode override")
	for _, name := range []string{"agy", "claude", "codex", "grok"} {
		providers[name] = flag.String(name, "", name+" executable")
	}
	for _, name := range []string{"agy-login", "codex-login", "codex-config", "grok-login", "grok-config"} {
		privateFiles[name] = flag.String(name, "", name+" input")
	}
	flag.StringVar(&claudeCredentialEnv, "claude-credential-env", "", "Claude credential environment selector")
	flag.Parse()
	if milestone != "native-agents" || expectedCommit == "" || binary == "" || runtime == "" || previous == "" || buildManifest == "" || bundleManifest == "" || output == "" || builderCommand == "" {
		fatal(errors.New("milestone, expected-commit, binary, runtime, previous, manifests, builder command and output are required"))
	}
	for name, path := range providers {
		if *path == "" {
			fatal(fmt.Errorf("%s executable is required", name))
		}
	}
	for name, path := range privateFiles {
		if *path == "" {
			fatal(fmt.Errorf("%s input is required", name))
		}
	}
	if claudeCredentialEnv != "ANTHROPIC_API_KEY" {
		fatal(errors.New("Claude credential selector must be ANTHROPIC_API_KEY"))
	}
	commit, err := cleanCommit()
	if err != nil {
		fatal(err)
	}
	if commit != expectedCommit {
		fatal(errors.New("promotion commit changed while gates were running"))
	}
	r := receipt{
		Schema:        1,
		Milestone:     milestone,
		Commit:        commit,
		CreatedAt:     time.Now().UTC().Format(time.RFC3339Nano),
		Providers:     map[string]provider{},
		PrivateInputs: map[string]privateInput{},
		PassedGates: []string{
			"real-agy-cold-recovery", "real-claude-cold-recovery",
			"real-codex-cold-recovery", "real-grok-cold-recovery",
			"repository", "full-check", "native-check", "standalone",
			"native-binary", "offline-boot", "native-client",
			"independent-displays", "agent-recovery", "agent-crash-recovery",
			"application-upgrade", "project-state-upgrade-rollback",
		},
	}
	for _, suffix := range artifactSuffixes {
		item, err := inspect(binary + suffix)
		if err != nil {
			fatal(err)
		}
		r.Artifacts = append(r.Artifacts, item)
	}
	if r.Runtime, err = inspect(runtime); err != nil {
		fatal(err)
	}
	if r.Previous, err = inspect(previous); err != nil {
		fatal(err)
	}
	if r.BuildManifest, err = inspect(buildManifest); err != nil {
		fatal(err)
	}
	if r.BundleManifest, err = inspect(bundleManifest); err != nil {
		fatal(err)
	}
	for name, path := range providers {
		item, err := inspect(*path)
		if err != nil {
			fatal(err)
		}
		version, err := executableVersion(*path)
		if err != nil {
			fatal(fmt.Errorf("%s version: %w", name, err))
		}
		r.Providers[name] = provider{Path: item.Path, SHA256: item.SHA256, Version: version}
	}
	for name, path := range privateFiles {
		item, err := inspect(*path)
		if err != nil {
			fatal(err)
		}
		r.PrivateInputs[name] = privateInput{SHA256: item.SHA256, Bytes: item.Bytes, Present: true}
	}
	credential, credentialPresent := os.LookupEnv(claudeCredentialEnv)
	credentialPresent = credentialPresent && credential != ""
	r.PrivateInputs["claude-credential"] = privateInput{Env: claudeCredentialEnv, Present: credentialPresent}
	if !credentialPresent {
		fatal(errors.New("Claude credential disappeared after its live gate"))
	}
	provenance, err := os.ReadFile(binary + ".provenance.json")
	if err != nil {
		fatal(err)
	}
	if !json.Valid(provenance) {
		fatal(errors.New("candidate provenance is not valid JSON"))
	}
	if err := verifyProvenance(provenance, r.Artifacts, buildManifest, bundleManifest); err != nil {
		fatal(err)
	}
	if r.PackAudit, err = auditPackManifest(runtime, bundleManifest); err != nil {
		fatal(err)
	}
	if r.Invocation, err = promotionInvocation(expectedCommit, binary, runtime, previous, buildManifest, bundleManifest, output, agyModel, builderCommand, beeVersion, beeMode, providers, claudeCredentialEnv); err != nil {
		fatal(err)
	}
	r.Provenance = provenance
	encoded, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		fatal(err)
	}
	encoded = append(encoded, '\n')
	if err := writeAtomic(output, encoded); err != nil {
		fatal(err)
	}
	fmt.Printf("Native Agents promotion evidence: %s\n", output)
}

func cleanCommit() (string, error) {
	status, err := exec.Command("git", "status", "--porcelain", "--untracked-files=all").Output()
	if err != nil {
		return "", err
	}
	if len(status) != 0 {
		return "", errors.New("promotion receipt requires a clean immutable commit")
	}
	output, err := exec.Command("git", "rev-parse", "HEAD").Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(output)), nil
}

func inspect(path string) (artifact, error) {
	info, err := os.Stat(path)
	if err != nil {
		return artifact{}, err
	}
	if !info.Mode().IsRegular() {
		return artifact{}, fmt.Errorf("%s is not a regular file", path)
	}
	file, err := os.Open(path)
	if err != nil {
		return artifact{}, err
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return artifact{}, err
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return artifact{}, err
	}
	return artifact{Path: abs, SHA256: hex.EncodeToString(hash.Sum(nil)), Bytes: info.Size()}, nil
}

func executableVersion(path string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, path, "--version")
	home, err := os.MkdirTemp("", "bee-provider-version-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(home)
	command.Env = []string{"HOME=" + home, "PATH=/usr/local/bin:/usr/bin:/bin", "NO_COLOR=1", "TERM=dumb"}
	output, err := command.CombinedOutput()
	if ctx.Err() != nil {
		return "", ctx.Err()
	}
	if err != nil {
		return "", err
	}
	value := strings.TrimSpace(string(output))
	if value == "" || len(value) > 200 || strings.ContainsAny(value, "\r\n") || !regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9 ._()+-]*$`).MatchString(value) {
		return "", errors.New("invalid version output")
	}
	return value, nil
}

type manifestArtifact struct {
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
}

type nativeComponent struct {
	Module  string `json:"module"`
	Version string `json:"version"`
	Package string `json:"package"`
	Factory string `json:"factory"`
	Private bool   `json:"private"`
	Launch  bool   `json:"launch"`
}

type buildDocument struct {
	Schema  int    `json:"schema"`
	Name    string `json:"name"`
	Runtime struct {
		Repository string             `json:"repository"`
		Commit     string             `json:"commit"`
		Go         string             `json:"go"`
		Tags       []string           `json:"tags"`
		Patches    []manifestArtifact `json:"patches"`
	} `json:"runtime"`
	Application struct {
		Module  string            `json:"module"`
		Command string            `json:"command"`
		Mode    string            `json:"mode"`
		DataEnv map[string]string `json:"data_env"`
		Packs   []struct {
			Module  string `json:"module"`
			Version string `json:"version"`
			Path    string `json:"path"`
			SHA256  string `json:"sha256"`
		} `json:"packs"`
		Baseline string `json:"baseline"`
	} `json:"application"`
	Native []nativeComponent `json:"native"`
}

type builderIdentity struct {
	Revision string `json:"revision"`
	Modified *bool  `json:"modified"`
	Go       string `json:"go"`
}

func verifyProvenance(data []byte, artifacts []artifact, buildManifest, bundleManifest string) error {
	var document struct {
		Schema    int               `json:"schema"`
		Mode      string            `json:"mode"`
		Manifest  json.RawMessage   `json:"manifest"`
		Builder   builderIdentity   `json:"builder"`
		Artifacts map[string]string `json:"artifacts"`
	}
	if err := json.Unmarshal(data, &document); err != nil {
		return err
	}
	if document.Schema != 1 || document.Mode != "application" {
		return errors.New("candidate provenance has an unsupported schema or mode")
	}
	if document.Builder.Revision == "" || document.Builder.Go == "" || document.Builder.Modified == nil || *document.Builder.Modified {
		return errors.New("candidate provenance has no clean builder identity")
	}
	if len(artifacts) != len(artifactSuffixes) {
		return errors.New("candidate artifact inventory is incomplete")
	}
	want := map[string]string{
		"binary":          artifacts[0].SHA256,
		"licenses":        artifacts[1].SHA256,
		"go.mod":          artifacts[2].SHA256,
		"go.sum":          artifacts[3].SHA256,
		"runtime-patches": artifacts[5].SHA256,
	}
	for key, digest := range want {
		if document.Artifacts[key] != digest {
			return fmt.Errorf("candidate %s does not match provenance", key)
		}
	}
	buildData, err := os.ReadFile(buildManifest)
	if err != nil {
		return err
	}
	bundleData, err := os.ReadFile(bundleManifest)
	if err != nil {
		return err
	}
	var source, bundle buildDocument
	if err := json.Unmarshal(buildData, &source); err != nil {
		return fmt.Errorf("decode build manifest: %w", err)
	}
	if err := json.Unmarshal(bundleData, &bundle); err != nil {
		return fmt.Errorf("decode bundle manifest: %w", err)
	}
	if err := validateManifest("build", source, false); err != nil {
		return err
	}
	if err := validateManifest("bundle", bundle, true); err != nil {
		return err
	}
	if err := compareManifestInputs(source, bundle); err != nil {
		return err
	}
	var provenanceManifest, sealedManifest any
	if err := json.Unmarshal(document.Manifest, &provenanceManifest); err != nil {
		return fmt.Errorf("decode provenance manifest: %w", err)
	}
	if err := json.Unmarshal(bundleData, &sealedManifest); err != nil {
		return err
	}
	if !reflect.DeepEqual(provenanceManifest, sealedManifest) {
		return errors.New("candidate provenance does not match the sealed bundle manifest")
	}
	return nil
}

func validateManifest(label string, manifest buildDocument, requireBaseline bool) error {
	if manifest.Schema != 1 || manifest.Name != "bee" {
		return fmt.Errorf("%s manifest has an unsupported schema or identity", label)
	}
	app := manifest.Application
	if app.Module != "bee/bee" || app.Command != "bee" || app.Mode == "" ||
		(requireBaseline && app.Baseline != "embedded") || (!requireBaseline && app.Baseline != "" && app.Baseline != "embedded") {
		return fmt.Errorf("%s manifest has an invalid Bee application identity", label)
	}
	if manifest.Runtime.Repository == "" || manifest.Runtime.Commit == "" || manifest.Runtime.Go == "" {
		return fmt.Errorf("%s manifest has an incomplete runtime identity", label)
	}
	if len(app.Packs) == 0 || len(manifest.Native) == 0 {
		return fmt.Errorf("%s manifest has an incomplete application or native inventory", label)
	}
	for _, patch := range manifest.Runtime.Patches {
		if patch.Path == "" || !regexp.MustCompile(`^[0-9a-f]{64}$`).MatchString(patch.SHA256) {
			return fmt.Errorf("%s manifest contains an invalid runtime patch", label)
		}
	}
	for _, component := range manifest.Native {
		if component.Module == "" || component.Version == "" || component.Package == "" || component.Factory == "" {
			return fmt.Errorf("%s manifest contains an incomplete native component", label)
		}
	}
	return nil
}

func compareManifestInputs(source, bundle buildDocument) error {
	if source.Schema != bundle.Schema || source.Name != bundle.Name ||
		source.Runtime.Repository != bundle.Runtime.Repository || source.Runtime.Commit != bundle.Runtime.Commit ||
		source.Runtime.Go != bundle.Runtime.Go || source.Application.Module != bundle.Application.Module ||
		source.Application.Command != bundle.Application.Command || source.Application.Mode != bundle.Application.Mode ||
		!reflect.DeepEqual(source.Application.DataEnv, bundle.Application.DataEnv) {
		return errors.New("build and bundle manifests disagree on immutable inputs")
	}
	if !equalStringSet(source.Runtime.Tags, bundle.Runtime.Tags) ||
		!equalDigestSet(source.Runtime.Patches, bundle.Runtime.Patches) ||
		!equalNativeSet(source.Native, bundle.Native) {
		return errors.New("build and bundle manifests disagree on runtime or native inputs")
	}
	return nil
}

func equalStringSet(left, right []string) bool {
	a, ok := uniqueStrings(left)
	if !ok {
		return false
	}
	b, ok := uniqueStrings(right)
	return ok && reflect.DeepEqual(a, b)
}

func uniqueStrings(values []string) (map[string]struct{}, bool) {
	result := make(map[string]struct{}, len(values))
	for _, value := range values {
		if value == "" {
			return nil, false
		}
		if _, exists := result[value]; exists {
			return nil, false
		}
		result[value] = struct{}{}
	}
	return result, true
}

func equalDigestSet(left, right []manifestArtifact) bool {
	a := make([]string, 0, len(left))
	for _, item := range left {
		a = append(a, item.SHA256)
	}
	b := make([]string, 0, len(right))
	for _, item := range right {
		b = append(b, item.SHA256)
	}
	return equalStringSet(a, b)
}

func equalNativeSet(left, right []nativeComponent) bool {
	key := func(value nativeComponent) string {
		return fmt.Sprintf("%s\x00%s\x00%s\x00%s\x00%t\x00%t", value.Module, value.Version, value.Package, value.Factory, value.Private, value.Launch)
	}
	a := make([]string, 0, len(left))
	for _, item := range left {
		a = append(a, key(item))
	}
	b := make([]string, 0, len(right))
	for _, item := range right {
		b = append(b, key(item))
	}
	return equalStringSet(a, b)
}

type ownedEntry struct {
	Kind  string `json:"kind"`
	Owner string `json:"owner"`
}

func auditPackManifest(runtime, path string) (packAudit, error) {
	return auditPackManifestWithLoader(path, func(_ string, packPath string) (map[string]string, error) {
		return loadPackedRegistry(runtime, packPath)
	})
}

func auditPackManifestWithLoader(path string, load func(module, packPath string) (map[string]string, error)) (packAudit, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return packAudit{}, err
	}
	var manifest struct {
		Application struct {
			Packs []struct{ Module, Path, SHA256 string } `json:"packs"`
		} `json:"application"`
	}
	if err := json.Unmarshal(data, &manifest); err != nil {
		return packAudit{}, err
	}
	if len(manifest.Application.Packs) == 0 {
		return packAudit{}, errors.New("sealed bundle contains no packs")
	}
	root := filepath.Dir(path)
	result := packAudit{}
	packPaths := make(map[string]string, len(manifest.Application.Packs))
	seenPaths := make(map[string]struct{}, len(manifest.Application.Packs))
	generation := filepath.Dir(filepath.Dir(filepath.Dir(manifest.Application.Packs[0].Path)))
	for _, pack := range manifest.Application.Packs {
		if pack.Module == "" {
			return result, errors.New("sealed pack has no module identity")
		}
		if _, exists := packPaths[pack.Module]; exists {
			return result, fmt.Errorf("sealed bundle repeats module %s", pack.Module)
		}
		if filepath.Dir(filepath.Dir(filepath.Dir(pack.Path))) != generation {
			return result, errors.New("sealed packs do not share one bundle generation")
		}
		packPath, err := confinedPath(root, pack.Path)
		if err != nil {
			return result, err
		}
		item, err := inspect(packPath)
		if err != nil {
			return result, err
		}
		if item.SHA256 != pack.SHA256 {
			return result, errors.New("sealed pack digest changed")
		}
		if _, exists := seenPaths[packPath]; exists {
			return result, errors.New("sealed bundle repeats a pack path")
		}
		seenPaths[packPath] = struct{}{}
		packPaths[pack.Module] = packPath
	}
	ownership, err := confinedPath(root, filepath.Join(generation, "ownership.json"))
	if err != nil {
		return result, err
	}
	ownershipData, err := os.ReadFile(ownership)
	if err != nil {
		return result, err
	}
	var inventory struct {
		Assets  map[string]any        `json:"assets"`
		Entries map[string]ownedEntry `json:"entries"`
	}
	if err := json.Unmarshal(ownershipData, &inventory); err != nil {
		return result, err
	}
	expected := make(map[string]map[string]string, len(packPaths))
	for module := range packPaths {
		expected[module] = map[string]string{}
	}
	for identity, entry := range inventory.Entries {
		for _, segment := range regexp.MustCompile(`[._:-]+`).Split(strings.ToLower(identity), -1) {
			if segment == "test" || segment == "tests" || segment == "fixture" || segment == "fixtures" {
				return result, fmt.Errorf("test or fixture registration shipped: %s", identity)
			}
		}
		if entry.Kind == "" || entry.Owner == "" {
			return result, fmt.Errorf("ownership entry is incomplete: %s", identity)
		}
		if entry.Kind == "fs.embed" {
			return result, fmt.Errorf("Native Agents pack contains embedded filesystem entry: %s", identity)
		}
		entries, exists := expected[entry.Owner]
		if !exists {
			return result, fmt.Errorf("ownership entry names absent pack %s", entry.Owner)
		}
		entries[identity] = entry.Kind
	}
	for module, packPath := range packPaths {
		if len(expected[module]) == 0 {
			return result, fmt.Errorf("sealed pack owns no registry entries: %s", module)
		}
		actual, err := load(module, packPath)
		if err != nil {
			return result, fmt.Errorf("load sealed pack %s: %w", module, err)
		}
		if !reflect.DeepEqual(actual, expected[module]) {
			return result, fmt.Errorf("sealed pack registry differs from ownership inventory: %s", module)
		}
		for identity, kind := range actual {
			if kind == "fs.embed" {
				return result, fmt.Errorf("Native Agents pack loads embedded filesystem entry: %s", identity)
			}
		}
	}
	result.Entries = len(inventory.Entries)
	result.Packs = len(packPaths)
	result.EmbeddedAssets = len(inventory.Assets)
	if result.EmbeddedAssets != 0 {
		return result, errors.New("Native Agents pack unexpectedly embeds filesystem assets")
	}
	return result, nil
}

func loadPackedRegistry(runtime, packPath string) (map[string]string, error) {
	if runtime == "" {
		return nil, errors.New("promotion runtime is required for pack audit")
	}
	root, err := os.MkdirTemp("", "bee-promotion-pack-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(root)
	home := filepath.Join(root, "home")
	if err := os.Mkdir(home, 0700); err != nil {
		return nil, err
	}
	absPack, err := filepath.Abs(packPath)
	if err != nil {
		return nil, err
	}
	lock := fmt.Sprintf("version: '1.0'\ndirectories:\n  modules: ./vendor\n  src: %q\nmodules: []\n", absPack)
	lockPath := filepath.Join(root, "wippy.lock")
	if err := os.WriteFile(lockPath, []byte(lock), 0600); err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, runtime, "--silent", "registry", "list", "--lock-file", lockPath, "--json")
	command.Dir = root
	command.Env = []string{"HOME=" + home, "PATH=/usr/local/bin:/usr/bin:/bin", "NO_COLOR=1", "TERM=dumb"}
	output, err := command.Output()
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			return nil, fmt.Errorf("registry list: %w: %s", err, strings.TrimSpace(string(exit.Stderr)))
		}
		return nil, fmt.Errorf("registry list: %w", err)
	}
	var rows []struct {
		ID   string `json:"id"`
		Kind string `json:"kind"`
	}
	if err := json.Unmarshal(output, &rows); err != nil {
		return nil, fmt.Errorf("decode registry list: %w", err)
	}
	entries := make(map[string]string, len(rows))
	for _, row := range rows {
		if row.ID == "" || row.Kind == "" {
			return nil, errors.New("loaded registry contains an incomplete entry")
		}
		if _, exists := entries[row.ID]; exists {
			return nil, fmt.Errorf("loaded registry repeats identity %s", row.ID)
		}
		entries[row.ID] = row.Kind
	}
	return entries, nil
}

func confinedPath(root, relative string) (string, error) {
	clean := filepath.Clean(relative)
	if filepath.IsAbs(clean) || clean == "." || clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
		return "", errors.New("bundle artifact path escapes its manifest directory")
	}
	rootPath, err := filepath.EvalSymlinks(root)
	if err != nil {
		return "", err
	}
	candidate, err := filepath.EvalSymlinks(filepath.Join(root, clean))
	if err != nil {
		return "", err
	}
	relativeToRoot, err := filepath.Rel(rootPath, candidate)
	if err != nil || relativeToRoot == ".." || strings.HasPrefix(relativeToRoot, ".."+string(filepath.Separator)) {
		return "", errors.New("bundle artifact resolves outside its manifest directory")
	}
	return candidate, nil
}

func promotionInvocation(commit, binary, runtime, previous, buildManifest, bundleManifest, output, agyModel, builderCommand, beeVersion, beeMode string, providers map[string]*string, claudeEnv string) (invocation, error) {
	makefile, err := inspect("build/native.mk")
	if err != nil {
		return invocation{}, err
	}
	variables := map[string]string{
		"MILESTONE":             "native-agents",
		"PROMOTION_COMMIT":      commit,
		"BEE_BINARY":            binary,
		"NATIVE_WIPPY":          runtime,
		"PREVIOUS_BEE":          previous,
		"BEE_BUILD_MANIFEST":    buildManifest,
		"BEE_BUNDLE_MANIFEST":   bundleManifest,
		"PROMOTION_RECEIPT":     output,
		"BUILDER":               builderCommand,
		"BEE_VERSION":           beeVersion,
		"BEE_MODE":              beeMode,
		"AGY_BIN":               *providers["agy"],
		"AGY_MODEL":             agyModel,
		"CLAUDE_BIN":            *providers["claude"],
		"CLAUDE_CREDENTIAL_ENV": claudeEnv,
		"CODEX_BIN":             *providers["codex"],
		"GROK_BIN":              *providers["grok"],
	}
	return invocation{
		EntryTarget:   "make promotion-check",
		GateTarget:    "make promotion-native-agents-check",
		Makefile:      makefile,
		Variables:     variables,
		PrivateInputs: []string{"agy-login", "codex-login", "codex-config", "grok-login", "grok-config"},
	}, nil
}

func writeAtomic(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".promotion-receipt-*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0600); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return err
	}
	directory, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "promotion receipt:", err)
	os.Exit(1)
}
