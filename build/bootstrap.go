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

func run(dir, name string, args ...string) error {
	c := exec.Command(name, args...)
	c.Dir = dir
	c.Stdin = os.Stdin
	c.Stdout = os.Stdout
	c.Stderr = os.Stderr
	return c.Run()
}
func output(dir string, args ...string) (string, error) {
	c := exec.Command("git", args...)
	c.Dir = dir
	b, err := c.Output()
	return strings.TrimSpace(string(b)), err
}
func bootstrap() error {
	root, err := os.Getwd()
	if err != nil {
		return err
	}
	data, err := os.ReadFile(filepath.Join(root, "runtime", "builder.lock.json"))
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
	status, err := output(checkout, "status", "--porcelain", "--untracked-files=all")
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
	return run(root, binary, os.Args[1:]...)
}
func main() {
	if err := bootstrap(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
