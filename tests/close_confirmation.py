"""Opt-in close negotiation keeps a real PTY alive until accepted."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
from workspace import ROOT, RUNTIME
from tui_smoke import Desktop


def exercise(packed, responsive=True):
    with tempfile.TemporaryDirectory(prefix="bee-close-confirm-") as directory:
        project = Path(directory) / "project"
        shutil.copytree(ROOT / "src", project / "src")
        for name in (".wippy.yaml", "wippy.lock"):
            shutil.copy2(ROOT / name, project / name)
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
        pack = project / "guarded.wapp"
        if packed:
            subprocess.run([str(RUNTIME), "pack", str(pack)], cwd=project, check=True)
        ui = Desktop(directory, packed, project=project, pack_file=pack, apps=("bee.console:app",))
        prompt = "Close terminal?" if responsive else "Application did not respond"
        try:
            ui.wait("Terminal")
            ui.key(b"printf 'READY_%s\\n' 'PTY'\r")
            ui.wait("READY_PTY")
            ui.key(b"\x11")
            ui.wait("Quit Bee?", timeout=5)
            if responsive:
                ui.wait("Terminal busy")
            ui.pump(.4)
            assert ui.process.poll() is None
            ui.key(b"\x1b[24~")
            ui.pump(.4)
            ui.wait("Quit Bee?")
            ui.key(b"\x1b")
            ui.key(b"printf 'AFTER_%s\\n' 'CANCEL'\r")
            ui.wait("AFTER_CANCEL")
            ui.key(b"\x17")
            ui.wait(prompt)
            ui.pump(.6)
            assert prompt in ui.text(), ui.text()
            assert ui.process.poll() is None
            ui.key(b"\x1b")
            ui.pump(.3)
            assert prompt not in ui.text(), ui.text()
            ui.key(b"printf 'STILL_%s\\n' 'ALIVE'\r")
            ui.wait("STILL_ALIVE")
            ui.key(b"\x17")
            ui.wait(prompt)
            ui.key(b"\x1b[24~")
            ui.pump(.4)
            ui.wait(prompt)
            ui.key(b"\t\r")
            ui.pump(.7)
            assert "Terminal" not in ui.screen.display[0], ui.text()
            assert prompt not in ui.text(), ui.text()
            ui.quit()
            ui.close()
            ui = Desktop(directory, packed, project=project, pack_file=pack, apps=("bee.console:app", "bee.console:app"))
            ui.wait("Terminal")
            ui.key(b"\x0e")
            deadline = time.monotonic() + 5
            while ui.screen.display[0].count("Terminal") < 2 and time.monotonic() < deadline:
                ui.pump(.05)
            assert ui.screen.display[0].count("Terminal") == 2, ui.text()
            ui.key(b"\x11")
            ui.wait("Quit Bee?", timeout=5)
            assert ui.screen.display[0].count("Terminal") == 2, ui.text()
            started = time.monotonic()
            ui.key(b"\t\r")
            while ui.process.poll() is None and time.monotonic() - started < 2:
                ui.pump(.02)
            assert ui.process.poll() == 0, ui.text()
            assert time.monotonic() - started < 1, "Accepted shutdown was slow"

        finally:
            ui.close()
    print(f'Close {"pack" if packed else "source"}, {"responsive" if responsive else "unresponsive"}: PTY survives waiting/cancel, desktop quit cancel/accept, forged token denied, F12, explicit {"close" if responsive else "force stop"}')


if __name__ == "__main__":
    for packed in (False, True):
        exercise(packed)
    exercise(False, False)
