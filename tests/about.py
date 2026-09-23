"""Settings About acceptance for source and portable pack launches."""
import tempfile

from tui_smoke import Desktop


def exercise(packed):
    with tempfile.TemporaryDirectory(prefix="bee-about-") as directory:
        ui = Desktop(directory, packed=packed, apps=("bee.settings:app",))
        try:
            ui.wait("BEE SETTINGS", timeout=10)
            ui.key(b"\t\t\t")
            ui.wait("BEE SETTINGS · ABOUT", timeout=10)
            text = ui.text()
            for label in ("Version", "Build", "Source", "Runtime", "Native", "Website"):
                assert label in text, text
            assert "https://bee.wippy.ai" in text, text
            assert "development source (unknown)" in text, text
            ui.key(b"\x1b[24~")
            ui.wait("BEE SETTINGS · ABOUT", timeout=10)
            ui.resize(48, 16)
            ui.wait("BEE SETTINGS", timeout=10)
            ui.key(b"\x1b[6~" * 60)
            ui.wait("Website", timeout=10)
            ui.quit()
        finally:
            ui.close()
    print(f"Settings About {('pack' if packed else 'source')}: identity fields, F12 and compact scrolling")


if __name__ == "__main__":
    exercise(False)
    exercise(True)
