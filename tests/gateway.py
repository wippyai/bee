"""Gateway acceptance against an isolated component composition.

The fixture stages Gateway and the modules its exercised interfaces require.  Its
small root is deliberately a host: it selects the listener, endpoint, approval
and built-in MCP policies, while the test probe owns the managed listener and
its custom surface policy.
"""
from contextlib import ExitStack, contextmanager
from copy import deepcopy
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import yaml
from workspace import ROOT, RUNTIME, configure_managed_gateway, database_environment


# Gateway's direct imports bring the first five modules in; governance brings
# Sync, Approvals and Hub.  Codex is retained only for the configuration-scope
# proof in the probe.
MODULES = (
    "persist", "threads", "application", "sync", "approvals", "hub", "gov",
    "docs", "driver", "driver-codex", "gateway",
)

# These are host-owned choices, not Gateway implementation entries.  Reading
# the canonical declarations keeps this focused composition aligned with the
# real host policies without copying the production source tree into it.
HOST_ENTRIES = {
    "src/security/gateway/_index.yaml": {
        "gateway_admit_policy", "gateway_materialize_policy", "gateway_supervision_policy",
        "gateway_manage_policy", "gateway_tool_read_policy", "gateway_tool_message_policy",
        "gateway_tool_inbox_policy", "gateway_session_discover_policy",
        "gateway_session_send_denied_policy",
        "gateway_tool_launch_policy", "gateway_tool_overlay_policy", "gateway_tool_docs_policy",
        "gateway_tool_components_policy", "gateway_tool_delivery_policy",
        "gateway_tool_publish_policy", "gateway_tool_application_open_policy",
    },
    "src/security/approvals/_index.yaml": {
        "approval_store_policy", "approval_owner_policy", "approval_request_policy",
        "approval_decide_policy", "approval_consume_policy", "approval_manage_policy",
    },
    "src/security/threads/_index.yaml": {
        "thread_storage_policy", "thread_resource_policy", "thread_authority_client_policy",
        "thread_lifecycle_client_policy", "thread_create_policy", "thread_observe_policy",
        "thread_lifecycle_policy", "thread_carrier_policy", "thread_approval_policy",
        "thread_approval_client_policy", "thread_waiter_policy",
    },
    "src/_index.yaml": {"approver_policies", "docs_corpus", "governance_publication_profiles",
                         "governance_activation_profiles", "placement_path", "placement_host_files",
                         "placement_executor", "placement_admitted_roots", "placement_resource_mode"},
    "src/security/_index.yaml": {"ordinary_app_subsystem_boundary"},
    "src/security/placement/_index.yaml": {"placement_store_policy", "placement_exec_policy"},
    "src/security/docs/_index.yaml": {"docs_policy"},
}


def selected_host_entries():
    """Return host selections grouped by source namespace, without copying production src."""
    selected = {}
    for relative, names in HOST_ENTRIES.items():
        document = yaml.safe_load((ROOT / relative).read_text())
        assert document["namespace"] == "bee" or document["namespace"].startswith("bee.security"), relative
        available = {entry["name"]: entry for entry in document["entries"]}
        assert names <= available.keys(), f"missing host entries in {relative}: {sorted(names - available.keys())}"
        selected[relative] = {
            "version": "1.0",
            "namespace": document["namespace"],
            "entries": [deepcopy(entry) for entry in document["entries"] if entry["name"] in names],
        }
    return selected


def dependency(name, component, parameters=()):
    entry = {"name": name, "kind": "ns.dependency", "component": component, "version": "0.1.0-dev"}
    if parameters:
        entry["parameters"] = [{"name": parameter, "value": value} for parameter, value in parameters]
    return entry


def gateway_parameters(listener):
    return (
        ("target_db", "bee.gateway:db"),
        ("target_listener", listener),
        ("target_endpoint", "bee:gateway_endpoint"),
        ("target_hook_storage", "bee:gateway_host_environment"),
        ("target_approval_request_policy", "bee.security.approvals:approval_request_policy"),
        ("target_approval_consume_policy", "bee.security.approvals:approval_consume_policy"),
        ("target_tool_read_policy", "bee.security.gateway:gateway_tool_read_policy"),
        ("target_tool_message_policy", "bee.security.gateway:gateway_tool_message_policy"),
        ("target_tool_inbox_policy", "bee.security.gateway:gateway_tool_inbox_policy"),
        ("target_tool_discover_policy", "bee.security.gateway:gateway_session_discover_policy"),
        ("target_tool_send_grant_policy", "bee.security.gateway:gateway_session_send_denied_policy"),
        ("target_tool_launch_policy", "bee.security.gateway:gateway_tool_launch_policy"),
        ("target_tool_overlay_policy", "bee.security.gateway:gateway_tool_overlay_policy"),
        ("target_tool_docs_policy", "bee.security.gateway:gateway_tool_docs_policy"),
        ("target_tool_components_policy", "bee.security.gateway:gateway_tool_components_policy"),
        ("target_tool_delivery_policy", "bee.security.gateway:gateway_tool_delivery_policy"),
        ("target_tool_publish_policy", "bee.security.gateway:gateway_tool_publish_policy"),
        ("target_tool_application_open_policy", "bee.security.gateway:gateway_tool_application_open_policy"),
    )


def write_gateway_host(folder, native):
    """Write the fixture's root host and its two small host-selected resources."""
    listener = "bee:gateway_listener" if native else "bee.managed:listener"
    host_entries = selected_host_entries()
    entries = [
        {"name": "definition", "kind": "ns.definition", "meta": {"title": "Gateway fixture host"}},
        dependency("dependency_persist", "bee/persist"),
        dependency("dependency_threads", "bee/threads", (
            ("target_db", "bee.threads:db"),
            ("process_host", "bee:workers"),
            ("waiter_policies", ["bee.security.threads:thread_waiter_policy"]),
        )),
        dependency("dependency_application", "bee/application"),
        dependency("dependency_sync", "bee/sync", (("target_db", "bee.sync:db"), ("target_exports", "bee:sync_exports"), ("target_sender", "bee.gateway_probe:sync_sender"))),
        dependency("dependency_approvals", "bee/approvals", (
            ("target_db", "bee.approvals:db"),
            ("target_policies", "bee:approver_policies"),
            ("process_host", "bee:workers"),
            ("authority_policies", ["bee.security.approvals:approval_store_policy", "bee.security.approvals:approval_owner_policy"]),
            ("worker_policies", ["bee.security.approvals:approval_store_policy", "bee.security.approvals:approval_owner_policy",
                                 "bee.security.threads:thread_approval_policy", "bee.security.threads:thread_approval_client_policy"]),
        )),
        dependency("dependency_hub", "bee/hub", (("process_host", "bee:workers"),)),
        dependency("dependency_governance", "bee/governance", (
            ("target_db", "bee.governance:db"),
            ("target_publication_profiles", "bee:governance_publication_profiles"),
            ("target_activation_profiles", "bee:governance_activation_profiles"),
            ("target_approval_request_policy", "bee.security.approvals:approval_request_policy"),
            ("target_approval_consume_policy", "bee.security.approvals:approval_consume_policy"),
        )),
        dependency("dependency_docs", "bee/docs", (("target_corpus", "bee:docs_corpus"),)),
        dependency("dependency_driver", "bee/driver"),
        dependency("dependency_driver_codex", "bee/driver-codex", (
            ("host_environment", "bee:gateway_host_environment"),
            ("window_policy", "bee:codex_window_policy"),
            ("batch_policy", "bee:codex_batch_policy"),
            ("named_batch_policy", "bee:codex_named_batch_policy"),
        )),
        dependency("dependency_gateway", "bee/gateway", gateway_parameters(listener)),
        {"name": "workers", "kind": "process.host", "host": {"workers": 4, "max_processes": 24}, "lifecycle": {"auto_start": True}},
        {"name": "terminal", "kind": "terminal.host", "hide_logs": True, "lifecycle": {"auto_start": True}},
        {"name": "gateway_host_environment", "kind": "env.storage.os", "lifecycle": {"auto_start": True}},
        {"name": "gateway_endpoint", "kind": "registry.entry", "meta": {"type": "bee.gateway_endpoint"}, "data": {"address": "127.0.0.1:0"}},
        {"name": "sync_exports", "kind": "registry.entry", "data": {"exports": []}},
        {"name": "codex_window_policy", "kind": "registry.entry", "data": {}},
        {"name": "codex_batch_policy", "kind": "registry.entry", "data": {}},
        {"name": "codex_named_batch_policy", "kind": "registry.entry", "data": {}},
    ]
    entries.extend(host_entries["src/_index.yaml"]["entries"])
    if native:
        entries.extend([
            {"name": "gateway_listener", "kind": "http.service", "addr": "127.0.0.1:0", "lifecycle": {"auto_start": True}},
            {"name": "gateway_router", "kind": "http.router", "meta": {"server": "bee:gateway_listener"}, "prefix": "/"},
            {"name": "gateway_ready", "kind": "http.endpoint", "meta": {"router": "bee:gateway_router"}, "method": "GET", "path": "/ready", "func": "bee.gateway.api:ready_http"},
            {"name": "gateway_mcp", "kind": "http.endpoint", "meta": {"router": "bee:gateway_router"}, "method": "POST", "path": "/mcp/:action", "func": "bee.gateway.api:mcp_http"},
            {"name": "gateway_hook", "kind": "http.endpoint", "meta": {"router": "bee:gateway_router"}, "method": "POST", "path": "/hook/:action", "func": "bee.gateway.api:hook_http"},
            {"name": "gateway_hook_status", "kind": "http.endpoint", "meta": {"router": "bee:gateway_router"}, "method": "GET", "path": "/hook/:action/:event", "func": "bee.gateway.api:hook_status_http"},
            {"name": "gateway_hook_mcp", "kind": "http.endpoint", "meta": {"router": "bee:gateway_router"}, "method": "POST", "path": "/hook/:action/mcp", "func": "bee.gateway.api:hook_mcp_http"},
        ])
    (folder / "src").mkdir(exist_ok=True)
    (folder / "src" / "_index.yaml").write_text(yaml.safe_dump({"version": "1.0", "namespace": "bee", "entries": entries}, sort_keys=False))
    for relative, document in host_entries.items():
        if relative == "src/_index.yaml":
            continue
        target = folder / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(yaml.safe_dump(document, sort_keys=False))
    (folder / "src" / "placement").mkdir()
    (folder / "src" / "placement" / "_index.yaml").write_text(yaml.safe_dump({
        "version": "1.0", "namespace": "bee.placement.native", "entries": [
            {"name": "environment", "kind": "env.storage.os", "lifecycle": {"auto_start": True}},
            {"name": "db_path", "kind": "env.variable", "storage": "bee.placement.native:environment", "variable": "BEE_PLACEMENT_DB", "default": ".wippy/placement.db", "readonly": True},
            {"name": "db", "kind": "db.sql.sqlite", "file": "${env:bee.placement.native:db_path}", "lifecycle": {"auto_start": True}},
            {"name": "executor", "kind": "exec.native"},
        ],
    }, sort_keys=False))


def write_workspace_config(folder):
    modules = []
    replacements = {}
    for module in MODULES:
        document = yaml.safe_load((ROOT / "modules" / module / "wippy.yaml").read_text())
        name = f"{document['organization']}/{document['module']}"
        modules.append({"name": name, "version": document["version"]})
        replacements[name] = f"./modules/{module}"
    (folder / "wippy.lock").write_text(yaml.safe_dump({"directories": {"modules": ".wippy", "src": "./src"}, "modules": modules}, sort_keys=False))
    (folder / ".wippy.yaml").write_text(yaml.safe_dump({
        "version": "1.0",
        "registry": {"enable_history": True, "history_type": "sqlite", "history_path": ".wippy/registry.db"},
        "shutdown": {"timeout": "3s"},
        "workspace": {"replacements": replacements},
    }, sort_keys=False))


def add_custom_tool_policies(folder):
    """Give the endpoint exactly the fixture's non-builtin surface policies."""
    policies = ("bee.gateway_probe:context_tool_policy", "bee.gateway_probe:replacement_policy")
    api = folder / "modules" / "gateway" / "src" / "api" / "_index.yaml"
    api_document = yaml.safe_load(api.read_text())
    endpoint = next(entry for entry in api_document["entries"] if entry["name"] == "mcp_http")
    endpoint["security"]["policies"].extend(policies)
    api.write_text(yaml.safe_dump(api_document, sort_keys=False))

    security = folder / "modules" / "gateway" / "src" / "security" / "_index.yaml"
    security_document = yaml.safe_load(security.read_text())
    read_policy = next(entry for entry in security_document["entries"] if entry["name"] == "tool_policy_read_policy")
    read_policy["policy"]["resources"].extend(policies)
    security.write_text(yaml.safe_dump(security_document, sort_keys=False))


@contextmanager
def gateway_workspace():
    with tempfile.TemporaryDirectory(prefix="bee-gateway-") as directory:
        folder = Path(directory)
        native = os.environ.get("BEE_GATEWAY_NATIVE") == "1"
        for module in MODULES:
            shutil.copytree(ROOT / "modules" / module, folder / "modules" / module)
        shutil.copytree(ROOT / "tests/fixtures/modules/gateway/src/probe", folder / "src" / "probe")
        if not native:
            shutil.copytree(ROOT / "tests/fixtures/modules/gateway/src/managed", folder / "src" / "managed")
        shutil.copytree(ROOT / "src/corpus", folder / "src" / "corpus")
        write_gateway_host(folder, native)
        write_workspace_config(folder)
        add_custom_tool_policies(folder)
        address = "native" if native else configure_managed_gateway(folder)
        yield folder, address


def main():
    # The two probes execute together. Their independent /ready answers prove
    # fixture-local endpoint configuration prevents cross-runtime generation
    # conflicts rather than bypassing the gateway's generation verification.
    with ExitStack() as fixtures:
        workspaces = [fixtures.enter_context(gateway_workspace()) for _ in range(2)]
        addresses = [address for _, address in workspaces]
        if os.environ.get("BEE_GATEWAY_NATIVE") != "1":
            assert len(set(addresses)) == len(addresses), addresses
        runs = []
        try:
            for folder, _ in workspaces:
                runs.append(subprocess.Popen([str(RUNTIME), "run", "gateway-probe", "--set", f"registry.history_path={folder}/registry.db"],
                                             cwd=folder, env=database_environment(folder), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True))
            for run, (_, address) in zip(runs, workspaces):
                stdout, stderr = run.communicate(timeout=120)
                output = stdout + stderr
                assert run.returncode == 0, f"{address}: {output}"
                assert "Bearer" not in output, "token bytes reached captured output"
        finally:
            for run in runs:
                if run.poll() is None:
                    run.terminate()
            for run in runs:
                if run.poll() is None:
                    try:
                        run.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        run.kill()
                        run.wait()
    print("Gateway slices 1, 2 and hook endpoints: agent-requested access through the durable approval inbox, consumed-effect handoff recovery, binding-isolated grants, request/status replay, denied decisions and preserved deselection; configurable traits with stable dispatch, fixed/dynamic native context, binding isolation, concurrent selection CAS and revocation; authenticated caller-owned workspace create/edit/freeze with idempotent replay and cross-actor denial; explicitly admitted thread_message append with bound context, idempotent replay and conflict, default read-tool profile preservation; thread_sessions paging only the workspace's running sessions the subject reads over a complete stable scan, thread_message to a session by action, attempt or thread addressed to its action and naming the sender's, unreachable sessions refused as not found, and thread_notify registering once and telling the caller on its own thread when the session's turn ends; the MCP contract of listChanged with re-list after select, tools/list input/output schemas and annotations, schema-valid calls, cursor paging, structured results with the normalized error shape, and the authoring path of guide index, section, example, bounded docs windows, non-staging delivery preflight and the capability report; hook credentials separate from tool credentials, empty-body answers, occurrence identity with replay and conflict, "
          "ambiguity per delivery, allowlisted queue fields, Codex metadata classification, payload and queue bounds; authenticated loopback readiness with epoch and restart generation, admission without bytes, materialize once per credential generation, "
          "reissue as compare-and-set, supersession and revoke_attempt fenced by carrier epoch, cross-attempt and expiry and revocation refused, thread_read as the bound subject, "
          "bounded read-only thread_wait with no delivery mark, drain releasing an in-flight wait with an explicit outcome and refusing admissions, a new epoch fencing earlier bindings, and a real funcs.new():with_scope configuration renderer whose callee is denied placement store, executor, policy lookup and scope creation; ambient actor/context inheritance remains outside that separate renderer scope-only proof")


if __name__ == "__main__":
    main()
