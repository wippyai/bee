// SPDX-License-Identifier: MIT

//go:build !windows

package host

import (
	"os/exec"
	"strconv"
	"syscall"
	"testing"

	"github.com/stretchr/testify/require"
	lua "github.com/wippyai/go-lua"
	"github.com/wippyai/runtime/api/attrs"
	ctxapi "github.com/wippyai/runtime/api/context"
	"github.com/wippyai/runtime/api/process"
	secapi "github.com/wippyai/runtime/api/security"
	"github.com/wippyai/runtime/runtime/lua/engine"
)

type groupTestScope struct {
	secapi.Scope
	allowed string
}

func (s groupTestScope) Evaluate(actor secapi.Actor, action, resource string, _ attrs.Bag) secapi.Result {
	if actor.ID == "placement" && action == ObserveGroupAction && (s.allowed == "*" || resource == s.allowed) {
		return secapi.Allow
	}
	return secapi.Deny
}

// endedGroup runs a child that leads its own process group and reaps it; the
// returned id names a group without members.
func endedGroup(t *testing.T) int {
	t.Helper()
	child := exec.Command("true")
	child.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	require.NoError(t, child.Run())
	return child.Process.Pid
}

func runGroupScript(t *testing.T, script, allowed string) error {
	t.Helper()
	ctx, _ := ctxapi.OpenFrameContext(ctxapi.NewRootContext())
	require.NoError(t, secapi.SetActor(ctx, secapi.Actor{ID: "placement"}))
	require.NoError(t, secapi.SetScope(ctx, groupTestScope{allowed: allowed}))
	p, err := engine.NewProcess(engine.WithScript(script, "group-test.lua"), engine.WithModuleBinder(func(l *lua.LState) error {
		engine.LoadModuleDef(l, ProcessModule)
		return nil
	}))
	require.NoError(t, err)
	t.Cleanup(p.Close)
	require.NoError(t, p.Init(ctx, "", nil))
	var out process.StepOutput
	return p.Step(nil, &out)
}

func TestProcessGroupPresenceFollowsMembership(t *testing.T) {
	present, err := processGroupPresent(syscall.Getpgrp())
	require.NoError(t, err)
	require.True(t, present)
	child := exec.Command("sleep", "30")
	child.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	require.NoError(t, child.Start())
	pgid := child.Process.Pid
	present, err = processGroupPresent(pgid)
	require.NoError(t, err)
	require.True(t, present)
	require.NoError(t, syscall.Kill(-pgid, syscall.SIGKILL))
	_ = child.Wait()
	present, err = processGroupPresent(pgid)
	require.NoError(t, err)
	require.False(t, present)
}

func TestLuaGroupPresentReportsAnEndedGroupAbsent(t *testing.T) {
	ended := endedGroup(t)
	script := `local present, err = hostprocess.group_present(` + strconv.Itoa(ended) + `); assert(err == nil, tostring(err)); assert(present == false)
local own, own_err = hostprocess.group_present(` + strconv.Itoa(syscall.Getpgrp()) + `); assert(own_err == nil, tostring(own_err)); assert(own == true)
return true`
	require.NoError(t, runGroupScript(t, script, "*"))
}

func TestLuaGroupPresentRefusesWithoutPermissionOrForInvalidIds(t *testing.T) {
	ended := strconv.Itoa(endedGroup(t))
	refused := `local present, err = hostprocess.group_present(` + ended + `); assert(present == nil and err ~= nil); return true`
	require.NoError(t, runGroupScript(t, refused, "1"))
	for _, id := range []string{"0", "1", "-5"} {
		invalid := `local present, err = hostprocess.group_present(` + id + `); assert(present == nil and err ~= nil); return true`
		require.NoError(t, runGroupScript(t, invalid, "*"))
	}
	require.Error(t, runGroupScript(t, `local present = hostprocess.group_present(`+ended+`); assert(present == false); return true`, "1"))
}
