// SPDX-License-Identifier: MIT
// Command bootstrap runs Bee's pinned Go assembler from a verified checkout.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

func command(dir, name string, args ...string) *exec.Cmd {
	if name == "git" {
		args = append([]string{"-c", "core.autocrlf=false", "-c", "core.hooksPath=" + os.DevNull}, args...)
	}
	c := exec.Command(name, args...)
	c.Dir = dir
	for _, entry := range os.Environ() {
		key, _, _ := strings.Cut(entry, "=")
		switch key {
		case "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_PREFIX", "GOWORK", "GOFLAGS":
			continue
		}
		c.Env = append(c.Env, entry)
	}
	c.Env = append(c.Env, "GOWORK=off", "GOFLAGS=")
	return c
}

func run(dir, name string, args ...string) error {
	c := command(dir, name, args...)
	c.Stdin = os.Stdin
	c.Stdout = os.Stdout
	c.Stderr = os.Stderr
	return c.Run()
}
func output(dir string, args ...string) (string, error) {
	c := command(dir, "git", args...)
	b, err := c.Output()
	return strings.TrimSpace(string(b)), err
}
func bootstrap() error {
	root, err := os.Getwd()
	if err != nil {
		return err
	}
	data, err := os.ReadFile(filepath.Join(root, "build", "builder.lock.json"))
	if err != nil {
		return err
	}
	var lock struct {
		Repository string `json:"repository"`
		Commit     string `json:"commit"`
	}
	if err = json.Unmarshal(data, &lock); err != nil {
		return err
	}
	if !strings.HasPrefix(lock.Repository, "https://") || !regexp.MustCompile(`^[0-9a-f]{40}$`).MatchString(lock.Commit) {
		return fmt.Errorf("builder requires HTTPS source and an exact commit")
	}
	cache := filepath.Join(root, ".wippy", "tools", "builder")
	if err = os.MkdirAll(cache, 0755); err != nil {
		return err
	}
	checkout := filepath.Join(cache, lock.Commit)
	if _, err = os.Stat(checkout); os.IsNotExist(err) {
		stage, err := os.MkdirTemp(cache, "fetch-")
		if err != nil {
			return err
		}
		defer os.RemoveAll(stage)
		source := filepath.Join(stage, "source")
		repository := lock.Repository
		if override := os.Getenv("BEE_BUILDER_REPOSITORY"); override != "" {
			repository = override
		}
		if err = run(root, "git", "clone", "--no-checkout", repository, source); err != nil {
			return err
		}
		if err = run(source, "git", "checkout", "--detach", lock.Commit); err != nil {
			return err
		}
		if err = os.Rename(source, checkout); err != nil {
			return err
		}
	} else if err != nil {
		return err
	}
	head, err := output(checkout, "rev-parse", "HEAD")
	if err != nil {
		return err
	}
	status, err := output(checkout, "status", "--porcelain", "--untracked-files=all", "--ignored=matching")
	if err != nil {
		return err
	}
	if head != lock.Commit || status != "" {
		return fmt.Errorf("pinned builder checkout was modified")
	}
	binary := filepath.Join(cache, "bin", lock.Commit, "wippy-builder")
	if err = os.MkdirAll(filepath.Dir(binary), 0755); err != nil {
		return err
	}
	if err = run(checkout, "go", "build", "-mod=readonly", "-trimpath", "-o", binary, "./cmd/wippy-builder"); err != nil {
		return err
	}
	command := exec.Command(binary, os.Args[1:]...)
	command.Dir = root
	command.Env = os.Environ()
	command.Stdin, command.Stdout, command.Stderr = os.Stdin, os.Stdout, os.Stderr
	// A development build (BEE_NATIVE_LOCAL=1) serves the checked-out native
	// module through a file proxy at a worktree pseudo-version. The pinned
	// builder otherwise resolves such modules through direct VCS by recomputing
	// GOPRIVATE/GONOPROXY/GONOSUMDB, so publish the dev overrides to its child
	// environment. The release path sets none of these.
	if os.Getenv("BEE_NATIVE_LOCAL") != "" {
		command.Env = append(command.Env, "GOPRIVATE=none", "GONOPROXY=none")
	}
	return command.Run()
}
func main() {
	if err := bootstrap(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
