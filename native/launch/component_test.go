// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/wippyai/runtime/api/boot"
	envapi "github.com/wippyai/runtime/api/env"
	"github.com/wippyai/runtime/api/registry"
	bootpkg "github.com/wippyai/runtime/boot"
	bootsystem "github.com/wippyai/runtime/boot/components/system"
	app "github.com/wippyai/runtime/cmd/app"
	envsystem "github.com/wippyai/runtime/system/env"
	"go.uber.org/zap"
)

func TestPlanUsesProjectDefaultAndLeavesExplicitStateAlone(t *testing.T) {
	root := filepath.Join(t.TempDir(), "state")
	project := makeProject(t)
	host := newHost(systemHostResolver())

	plan, err := host.Plan(context.Background(), app.Launch{Dir: project, State: root})
	if err != nil {
		t.Fatal(err)
	}
	want, err := ProjectStateDir(root, project)
	if err != nil {
		t.Fatal(err)
	}
	if plan.DefaultState != want {
		t.Fatalf("default state = %q, want %q", plan.DefaultState, want)
	}

	explicit := filepath.Join(t.TempDir(), "chosen")
	plan, err = host.Plan(context.Background(), app.Launch{Dir: project, State: explicit, Explicit: true})
	if err != nil {
		t.Fatal(err)
	}
	if plan.DefaultState != "" {
		t.Fatalf("explicit launch received default state %q", plan.DefaultState)
	}
}

// launchThroughRuntime runs the executable's own argument grammar with the
// production host and returns the launch the client route receives.
func launchThroughRuntime(t *testing.T, args []string) app.Launch {
	t.Helper()
	host := Component()
	var routed []app.Launch
	host.clientRoute = func(_ context.Context, launch app.Launch, _ clientIntent) error {
		routed = append(routed, launch)
		return nil
	}
	executable := app.Executable{Name: desktopCommand, Command: desktopCommand, Host: host}
	if err := app.Run(context.Background(), executable, args); err != nil {
		t.Fatal(err)
	}
	if len(routed) != 1 {
		t.Fatalf("client route ran %d times", len(routed))
	}
	return routed[0]
}

// A plain bee run selects this project's state under the config root, and
// --state replaces that selection.
func TestRuntimeClientLaunchUsesProjectState(t *testing.T) {
	scratch := t.TempDir()
	config := filepath.Join(scratch, "config")
	t.Setenv("HOME", filepath.Join(scratch, "home"))
	t.Setenv("XDG_CONFIG_HOME", config)
	project := makeProject(t)
	t.Chdir(project)

	root, err := os.UserConfigDir()
	if err != nil {
		t.Fatal(err)
	}
	want, err := ProjectStateDir(filepath.Join(root, desktopCommand), project)
	if err != nil {
		t.Fatal(err)
	}
	if got := launchThroughRuntime(t, []string{}).State; got != want {
		t.Fatalf("client state = %q, want %q", got, want)
	}

	explicit := filepath.Join(scratch, "chosen")
	if got := launchThroughRuntime(t, []string{"--state", explicit}).State; got != explicit {
		t.Fatalf("client state = %q, want explicit %q", got, explicit)
	}
}

// A non-explicit owner start carries the runtime's default root in its launch;
// the owner's enrollment state is the project state the runtime opens.
func TestPlanOwnerStartUsesProjectState(t *testing.T) {
	root := filepath.Join(t.TempDir(), "config", desktopCommand)
	project := makeProject(t)
	host := newHost(systemHostResolver())
	plan, err := host.Plan(context.Background(), app.Launch{
		Op: app.OpRun, Command: desktopCommand, Args: []string{ownerArgument}, State: root, Dir: project,
	})
	if err != nil {
		t.Fatal(err)
	}
	want, err := ProjectStateDir(root, project)
	if err != nil {
		t.Fatal(err)
	}
	if plan.DefaultState != want || host.ownerState != want {
		t.Fatalf("owner state = %q, runtime state = %q, want %q", host.ownerState, plan.DefaultState, want)
	}
}

func TestPlanMapsOnlyExplicitOwnerStart(t *testing.T) {
	host := newHost(systemHostResolver())
	project := makeProject(t)
	plan, err := host.Plan(context.Background(), app.Launch{
		Dir: project, State: t.TempDir(), Explicit: true, Op: app.OpRun,
		Command: desktopCommand, Args: []string{ownerArgument},
	})
	if err != nil {
		t.Fatal(err)
	}
	if plan.Command != ownerCommand || plan.Args == nil || len(plan.Args) != 0 {
		t.Fatalf("owner plan = command %q args %#v", plan.Command, plan.Args)
	}

	ordinary, err := host.Plan(context.Background(), app.Launch{
		Dir: project, State: t.TempDir(), Explicit: true, Op: app.OpRun,
		Command: desktopCommand, Args: []string{"agent"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if ordinary.Command != "" || ordinary.Args != nil {
		t.Fatalf("ordinary launch was remapped: command %q args %#v", ordinary.Command, ordinary.Args)
	}

	if _, err := host.Plan(context.Background(), app.Launch{
		Dir: project, State: t.TempDir(), Explicit: true, Op: app.OpRun,
		Command: desktopCommand, Args: []string{ownerArgument, "extra"},
	}); err == nil {
		t.Fatal("owner start accepted extra arguments")
	}
}

// bee daemon runs the node from the project state like bee start, under its
// own owner command, and never reads its arguments as a client intent.
func TestPlanMapsDaemonToTheNodeWithoutAFolderWorkspace(t *testing.T) {
	root := filepath.Join(t.TempDir(), "config", desktopCommand)
	project := makeProject(t)
	host := newHost(systemHostResolver())
	plan, err := host.Plan(context.Background(), app.Launch{
		Op: app.OpRun, Command: desktopCommand, Args: []string{daemonArgument}, State: root, Dir: project,
	})
	if err != nil {
		t.Fatal(err)
	}
	want, err := ProjectStateDir(root, project)
	if err != nil {
		t.Fatal(err)
	}
	if plan.Command != daemonCommand || plan.Args == nil || len(plan.Args) != 0 || plan.Prepare == nil || plan.Run != nil {
		t.Fatalf("daemon plan = command %q args %#v prepare %v run %v", plan.Command, plan.Args, plan.Prepare != nil, plan.Run != nil)
	}
	if plan.DefaultState != want || host.ownerState != want {
		t.Fatalf("daemon state = %q, runtime state = %q, want %q", host.ownerState, plan.DefaultState, want)
	}
	if _, err := newHost(systemHostResolver()).Plan(context.Background(), app.Launch{
		Op: app.OpRun, Command: desktopCommand, Args: []string{daemonArgument, "extra"}, State: t.TempDir(), Dir: project, Explicit: true,
	}); err == nil {
		t.Fatal("daemon accepted extra arguments")
	}
}

func TestPlanRoutesOrdinaryLaunchThroughClientAndOwnerThroughPrepare(t *testing.T) {
	state := t.TempDir()
	host := newHost(systemHostResolver())
	project := makeProject(t)

	// An ordinary launch is the client route: the host decides ownership, so the
	// runtime must not open the client's state itself.
	client, err := host.Plan(context.Background(), app.Launch{
		Op: app.OpRun, Command: desktopCommand, Args: []string{"agent"},
		State: state, Dir: project, Explicit: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if client.Run == nil {
		t.Fatal("ordinary launch has no client Run")
	}
	if client.Prepare != nil {
		t.Fatal("ordinary launch prepared owner resources")
	}
	if client.Command != "" || client.Args != nil || client.DefaultState != "" {
		t.Fatalf("client plan leaked runtime selection: %#v", client)
	}

	// An explicit application ID keeps the runtime's own entry for recovery and
	// development launches.
	application, err := host.Plan(context.Background(), app.Launch{
		Op: app.OpRun, Command: desktopCommand, Args: []string{"bee.harness.window:app"},
		State: state, Dir: project, Explicit: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if application.Run != nil || application.Prepare != nil {
		t.Fatalf("explicit application ID was routed through the client: %#v", application)
	}

	// The owner route prepares resources and records the state for the
	// enrollment publisher the host starts.
	owner, err := host.Plan(context.Background(), app.Launch{
		Op: app.OpRun, Command: desktopCommand, Args: []string{ownerArgument},
		State: state, Dir: project, Explicit: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if owner.Prepare == nil || owner.Run != nil {
		t.Fatalf("owner plan = prepare %v run %v", owner.Prepare != nil, owner.Run != nil)
	}
	if owner.Command != ownerCommand {
		t.Fatalf("owner command = %q", owner.Command)
	}
	if host.ownerState != state {
		t.Fatalf("host owner state = %q, want %q", host.ownerState, state)
	}
}

func TestHostStartAddsEnrollmentPublisherForOwner(t *testing.T) {
	state := t.TempDir()
	host := newHost(systemHostResolver())
	// A client launch starts nothing.
	if err := host.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(host.components) != 0 {
		t.Fatalf("client launch added components: %#v", host.components)
	}
	// After planning an owner launch the host owns the owner components. Their
	// Start needs the live cluster and registry the runtime boots, so this test
	// asserts the wiring the host will start, not the cluster itself.
	if _, err := host.Plan(context.Background(), app.Launch{
		Op: app.OpRun, Command: desktopCommand, Args: []string{ownerArgument},
		State: state, Dir: state, Explicit: true,
	}); err != nil {
		t.Fatal(err)
	}
	_, release, err := prepareOwner(state, true)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = release() }()
	components, err := ownerComponents(state, "0123456789abcdef0123456789abcdef", "")
	if err != nil {
		t.Fatal(err)
	}
	names := []string{}
	for _, component := range components {
		names = append(names, component.Name())
	}
	if len(names) != 3 || names[0] != "bee.hive.rendezvous" || names[1] != "bee.launch.join" || names[2] != "bee.launch.enrollment" {
		t.Fatalf("owner components = %v", names)
	}
	_ = bootpkg.NewBootstrapContext
	_ = registry.WithRegistry
	_ = zap.NewNop
}

// enrollmentRegistryStub is an inert registry for the host Start test.
type enrollmentRegistryStub struct{}

func (enrollmentRegistryStub) GetAllEntries() ([]registry.Entry, error) { return nil, nil }
func (enrollmentRegistryStub) GetEntry(registry.ID) (registry.Entry, error) {
	return registry.Entry{}, nil
}
func (enrollmentRegistryStub) Apply(context.Context, registry.ChangeSet) (registry.Version, error) {
	return nil, nil
}
func (enrollmentRegistryStub) ApplyVersion(context.Context, registry.Version) error { return nil }
func (enrollmentRegistryStub) LoadState(context.Context, registry.State, registry.Version) error {
	return nil
}
func (enrollmentRegistryStub) Current() (registry.Version, error) { return nil, nil }
func (enrollmentRegistryStub) History() registry.History          { return nil }
func (enrollmentRegistryStub) Snapshot() registry.Snapshot        { return registry.Snapshot{} }
func (enrollmentRegistryStub) RegisterDependencyPattern(registry.DependencyPattern) error {
	return nil
}

func TestHostIsOneBootComponentAndHost(t *testing.T) {
	host := newHost(systemHostResolver())
	var _ boot.Component = host
	var _ app.Host = host
	if host.Name() != ComponentName {
		t.Fatalf("host name = %q", host.Name())
	}
	if len(host.DependsOn()) != 1 || host.DependsOn()[0] != bootsystem.EnvironmentName {
		t.Fatalf("host dependencies = %v", host.DependsOn())
	}
}

func TestHostRegistersReadOnlyEnvironment(t *testing.T) {
	root := t.TempDir()
	resolver := hostResolver{
		lookPath: func(name string) (string, error) {
			if name == "example-tool" {
				return filepath.Join(root, "bin", name), nil
			}
			return "", errors.New("not found")
		},
		homeDir:    func() (string, error) { return filepath.Join(root, "home"), nil },
		getwd:      func() (string, error) { return filepath.Join(root, "work"), nil },
		executable: func() (string, error) { return filepath.Join(root, "bin", "bee"), nil },
	}
	host := newHost(resolver)
	ctx, err := bootpkg.NewBootstrapContext(zap.NewNop(), boot.NewConfig())
	if err != nil {
		t.Fatal(err)
	}
	environment := boot.New(boot.P{Name: bootsystem.EnvironmentName, Load: func(ctx context.Context) (context.Context, error) {
		return envapi.WithRegistry(ctx, envsystem.NewRegistry(nil, zap.NewNop())), nil
	}})
	loader, err := bootpkg.NewLoader(host, environment)
	if err != nil {
		t.Fatal(err)
	}
	ctx, err = loader.Load(ctx)
	if err != nil {
		t.Fatal(err)
	}
	environmentRegistry := envapi.GetRegistry(ctx)
	if environmentRegistry == nil {
		t.Fatal("environment registry missing")
	}
	storage, err := environmentRegistry.GetStorage(ctx, registry.ParseID(StorageID))
	if err != nil {
		t.Fatal(err)
	}
	if got, err := storage.Get(ctx, "example-tool"); err != nil || got != filepath.Join(root, "bin", "example-tool") {
		t.Fatalf("PATH lookup = %q, %v", got, err)
	}
	if _, err := storage.Get(ctx, filepath.Join(root, "bin", "example-tool")); !errors.Is(err, envapi.ErrVariableNotFound) {
		t.Fatalf("absolute lookup error = %v", err)
	}
	if err := storage.Set(ctx, "example-tool", "other"); err == nil {
		t.Fatal("read-only storage accepted Set")
	}
}
