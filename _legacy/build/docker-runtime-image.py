#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Build a Docker runtime from explicit CLI artifacts, never provider homes."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

BASE = "node@sha256:be23f54a88d34e8824c741b19b91064094f92c1c97b194144bfc8b50d67258e2"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--artifact", action="append", required=True, help="name=absolute CLI artifact path")
    arguments = parser.parse_args()
    arguments.output.mkdir(parents=True, exist_ok=True)
    artifacts = {}
    for item in arguments.artifact:
        name, source = item.split("=", 1)
        if name not in {"claude", "codex", "agy", "grok", "muse", "opencode"} or name in artifacts:
            parser.error("unknown or repeated runtime")
        path = Path(source).resolve(strict=True)
        if not path.is_file() or path.read_bytes()[:4] != b"\x7fELF":
            parser.error(f"{name} requires an explicit Linux executable artifact")
        artifacts[name] = path
    with tempfile.TemporaryDirectory(prefix="bee-docker-image-", dir=arguments.output) as directory:
        context = Path(directory)
        (context / "bin").mkdir()
        inputs = {}
        for name, path in artifacts.items():
            destination = context / "bin" / name
            shutil.copy2(path, destination)
            destination.chmod(0o755)
            inputs[name] = hashlib.sha256(destination.read_bytes()).hexdigest()
        runtime_labels = " ".join(f'bee.runtime.{name}="{digest}"' for name, digest in sorted(inputs.items()))
        recipe = f"""FROM {BASE}
LABEL bee.actor_ref="bee.runtime-image" bee.attempt_id="stock-runtime-build" {runtime_labels}
COPY bin/ /usr/local/bin/
ENV PATH="/usr/local/bin:/usr/bin:/bin" HOME="/home/bee"
USER 1000:1000
WORKDIR /home/bee
"""
        (context / "Dockerfile").write_text(recipe)
        print("Building Bee Docker runtimes: " + ", ".join(sorted(inputs)), flush=True)
        subprocess.run(["docker", "build", "--rm", "--force-rm", "--iidfile", str(context / "image-id"), str(context)], check=True)
        image = (context / "image-id").read_text().strip()
        descriptor = {"schema_revision": "bee.runtime-image@1", "image_ref": image, "base": BASE, "artifacts": inputs}
        (arguments.output / "runtime-image.json").write_text(json.dumps(descriptor, indent=2) + "\n")
        (arguments.output / "Dockerfile").write_text(recipe)
        print("Bee Docker runtime image: " + image, flush=True)


if __name__ == "__main__":
    main()
