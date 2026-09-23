"""Authenticated app titles stay independent of user window labels."""
from pathlib import Path
import shutil
import subprocess
import tempfile
from workspace import ROOT, RUNTIME
from tui_smoke import Desktop
from personalization import menu, rename


def exercise(packed):
    with tempfile.TemporaryDirectory(prefix="bee-app-titles-") as directory:
        project = Path(directory) / "project"
        shutil.copytree(ROOT / "src", project / "src")
        shutil.copytree(ROOT / "modules", project / "modules")
        for name in (".wippy.yaml", "wippy.lock", "wippy.yaml"):
            shutil.copy2(ROOT / name, project / name)
        source = project / "src/apps/settings/app.lua"
        code = source.read_text()
        anchor = "            local data = event.value"
        assert anchor in code
        code = code.replace(anchor, anchor + r'''
            if data.type == "key" and data.action ~= "release" then
                dirty = true
                if data.key == "!" then
                    assert(client.title(launch, "App Report"))
                    status = "Title sent"
                elseif data.key == "@" then
                    for i = 1, 25 do assert(client.title(launch, "Report " .. tostring(i))) end
                    status = "Burst sent"
                elseif data.key == "~" then
                    for _, request in ipairs({
                        {id = launch.view_id, token = "wrong", title = "Forged"},
                        {id = "foreign", token = launch.launch_token, title = "Forged"},
                        {id = launch.view_id, token = launch.launch_token, title = "\27[31m"},
                        {id = launch.view_id, token = launch.launch_token, title = string.rep("x", 81)},
                    }) do
                        assert(process.send(launch.broker_pid, "bee.application.title", {version = 1,
                            instance_id = launch.instance_id, id = request.id, launch_token = request.token, title = request.title}))
                    end
                    status = "Invalid attempts sent"
                elseif data.key == "=" then
                    assert(client.title(launch, ""))
                    status = "Reset sent"
                end
            end
''')
        source.write_text(code)
        subprocess.run([str(RUNTIME), "lint"], cwd=project, check=True)
        pack = project / "titles.wapp"
        if packed:
            subprocess.run([str(RUNTIME), "pack", str(pack)], cwd=project, check=True)
        ui = Desktop(directory, packed, project=project, pack_file=pack, apps=("bee.settings:app",))
        try:
            ui.wait("BEE SETTINGS")
            ui.key(b"!")
            ui.wait("App Report")
            rename(ui, "App Report", "Pinned")
            ui.key(b"@")
            ui.wait("Burst sent")
            ui.pump(.3)
            assert "Pinned" in ui.screen.display[0] and "Report 25" not in ui.screen.display[0], ui.text()
            menu(ui, "Pinned", "Rename…")
            ui.key(b"\x7f\r")
            ui.pump(.3)
            assert "Report 25" in ui.screen.display[0], ui.text()
            ui.key(b"~")
            ui.wait("Invalid attempts sent")
            ui.pump(.3)
            assert "Report 25" in ui.screen.display[0] and "Forged" not in ui.text(), ui.text()
            ui.key(b"\x1b[24~")
            ui.wait("Report 25")
            ui.key(b"=")
            ui.wait("Reset sent")
            ui.pump(.3)
            assert "Settings" in ui.screen.display[0], ui.text()
            ui.quit()
        finally:
            ui.close()
    print(f'App titles {"pack" if packed else "source"}: authenticated updates, burst final value, user override/clear, token/view/control/size denial, F12 and default reset')


if __name__ == "__main__":
    for packed in (False, True):
        exercise(packed)
