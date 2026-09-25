"""Opt-in close negotiation keeps a real PTY alive until accepted."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
from workspace import ROOT, RUNTIME, pack_deployment
from tui_smoke import DESKTOP_HANG_SECONDS, Desktop



def replaced_presenter(ui, prompt):
    previous = ui.screen.display[0]
    ui.key(b"\x1b[24~")
    deadline = time.monotonic() + DESKTOP_HANG_SECONDS
    while (ui.screen.display[0] == previous or prompt not in ui.text()) and time.monotonic() < deadline:
        ui.pump(.05)
    assert ui.screen.display[0] != previous and prompt in ui.text(), ui.text()


def canceled_prompt(ui, prompt):
    ui.key(b"\x1b")
    deadline = time.monotonic() + DESKTOP_HANG_SECONDS
    while prompt in ui.text() and time.monotonic() < deadline:
        ui.pump(.05)
    assert prompt not in ui.text(), ui.text()


def exercise(packed, responsive=True):
    with tempfile.TemporaryDirectory(prefix="bee-close-confirm-") as directory:
        project = Path(directory) / "project"
        shutil.copytree(ROOT / "src", project / "src")
        shutil.copytree(ROOT / "modules", project / "modules")
        for name in (".wippy.yaml", "wippy.lock", "wippy.yaml"):
            shutil.copy2(ROOT / name, project / name)
        presenter = project / "src/terminal/main.lua"
        presentation = presenter.read_text()
        label = '"Workspace " .. names.label(workspace_id)'
        assert presentation.count(label) == 1
        presenter.write_text(presentation.replace(label, label + ' .. " P:" .. tostring(process.pid()):sub(-8)'))
        source = project / "src/apps/console/app.lua"
        code = source.read_text()
        handler = '''        elseif selected.channel == closes then
            local request = client.close_request(launch, tostring(selected.value:from()), selected.value:payload():data())
'''
        if responsive:
            code = code.replace('    local input = assert(tty.events())',
                '    local query_results = assert(process.listen("bee.application.query.result", {message = true}))\n'
                '    local input = assert(tty.events())')
            code = code.replace('closes:case_receive()})', 'closes:case_receive(), query_results:case_receive()})')
            handler += '''            if request then
                assert(client.title(launch, "Terminal reviewing"))
                assert(client.query(launch, {kind = "confirm", title = "Must not open while closing"}))
                assert(process.send(launch.broker_pid, "bee.application.close.reply", {version = 1,
                    request_id = request.request_id, id = launch.view_id, instance_id = launch.instance_id,
                    launch_token = "forged", action = "accept"}))
                assert(client.close_reply(launch, request.request_id, {action = "confirm", title = "Close terminal?",
                    message = "Commands in this terminal will stop.", accept = "Close terminal"}))
            end
        elseif selected.channel == query_results then
            local result = client.query_result(launch, tostring(selected.value:from()), selected.value:payload():data())
            assert(result and result.error == "busy")
            assert(client.title(launch, "Terminal busy"))
'''
        begin = code.index("        elseif selected.channel == closes then")
        end = code.index("        elseif selected.channel == input then", begin)
        code = code[:begin] + handler + code[end:]
        source.write_text(code)
        subprocess.run([str(RUNTIME), "lint"], cwd=project, check=True)
        pack = project / "guarded-deployment"
        if packed:
            pack_deployment(project, pack)
        ui = Desktop(directory, packed, project=project, deployment=pack, apps=("bee.console:app",))
        prompt = "Close terminal?" if responsive else "Application did not respond"
        try:
            ui.wait("Terminal")
            ui.key(b"printf 'READY_%s\\n' 'PTY'\r")
            ui.wait("READY_PTY")
            ui.key(b"\x11")
            ui.wait("Quit Bee?")
            if responsive:
                ui.wait("Terminal busy")
            ui.pump(.4)
            assert ui.process.poll() is None
            replaced_presenter(ui, "Quit Bee?")
            canceled_prompt(ui, "Quit Bee?")
            ui.key(b"printf 'AFTER_%s\\n' 'CANCEL'\r")
            ui.wait("AFTER_CANCEL")
            ui.key(b"\x17")
            ui.wait(prompt)
            ui.pump(.6)
            assert prompt in ui.text(), ui.text()
            assert ui.process.poll() is None
            canceled_prompt(ui, prompt)
            ui.key(b"printf 'STILL_%s\\n' 'ALIVE'\r")
            ui.wait("STILL_ALIVE")
            ui.key(b"\x17")
            ui.wait(prompt)
            replaced_presenter(ui, prompt)
            ui.key(b"\t\r")
            deadline = time.monotonic() + DESKTOP_HANG_SECONDS
            while ("Terminal" in ui.screen.display[0] or prompt in ui.text()) and time.monotonic() < deadline:
                ui.pump(.05)
            assert "Terminal" not in ui.screen.display[0], ui.text()
            assert prompt not in ui.text(), ui.text()
            ui.quit()
            ui.close()
            ui = Desktop(directory, packed, project=project, deployment=pack, apps=("bee.console:app", "bee.console:app"))
            ui.wait("Terminal")
            ui.key(b"\x0e")
            deadline = time.monotonic() + DESKTOP_HANG_SECONDS
            while ui.screen.display[0].count("Terminal") < 2 and time.monotonic() < deadline:
                ui.pump(.05)
            assert ui.screen.display[0].count("Terminal") == 2, ui.text()
            ui.key(b"\x11")
            ui.wait("Quit Bee?")
            assert ui.screen.display[0].count("Terminal") == 2, ui.text()
            started = time.monotonic()
            ui.key(b"\t\r")
            while ui.process.poll() is None and time.monotonic() - started < DESKTOP_HANG_SECONDS:
                ui.pump(.02)
            assert ui.process.poll() == 0, ui.text()

        finally:
            ui.close()
    print(f'Close {"pack" if packed else "source"}, {"responsive" if responsive else "unresponsive"}: PTY survives waiting/cancel, desktop quit cancel/accept, forged token denied, F12, explicit {"close" if responsive else "force stop"}')


if __name__ == "__main__":
    for packed in (False, True):
        exercise(packed)
    exercise(False, False)
