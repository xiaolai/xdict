#!/usr/bin/env python3
"""Generate an ignored Xcode External Build System project that runs the actual development app."""
import json
from pathlib import Path
import shlex
import subprocess
import xml.etree.ElementTree as ET

apple = Path(__file__).resolve().parent.parent
out = apple / ".build/local-preview"
out.mkdir(parents=True, exist_ok=True)
spec = {
    "name": "XDictLive",
    "fileGroups": [str(apple / name) for name in ["Sources", "Resources", "Strings", "Package.swift"]],
    "targets": {
        "XDict": {
            "type": "application", "platform": "macOS", "deploymentTarget": "27.0",
            "legacy": {
                "toolPath": "/bin/bash", "arguments": shlex.quote(str(apple / "Tools/live-ui.sh")) + " build",
                "workingDirectory": str(apple), "passSettings": False,
            },
            "settings": {"base": {
                "PRODUCT_NAME": "XDict", "PRODUCT_BUNDLE_IDENTIFIER": "ai.xdict.app",
                "CONFIGURATION_BUILD_DIR": str(out),
            }},
        },
    },
    "schemes": {"XDictLive": {
        "build": {"targets": {"XDict": "all"}},
        "run": {"config": "Debug", "executable": "XDict", "debugEnabled": False},
    }},
}
spec_path = out / "project.json"
spec_path.write_text(json.dumps(spec, indent=2))
subprocess.run(["xcodegen", "generate", "--spec", str(spec_path), "--project", str(out)], check=True)
project = out / "XDictLive.xcodeproj"
scheme = project / "xcshareddata/xcschemes/XDictLive.xcscheme"
tree = ET.parse(scheme)
launch = tree.getroot().find("LaunchAction")
assert launch is not None
for child in list(launch):
    if child.tag in {"BuildableProductRunnable", "RemoteRunnable", "PathRunnable"}:
        launch.remove(child)
ET.SubElement(launch, "PathRunnable", {"runnableDebuggingMode": "0", "FilePath": str(out / "XDict.app")})
tree.write(scheme, encoding="utf-8", xml_declaration=True)
subprocess.run(["open", str(project)], check=True)
print(f"Choose XDictLive → My Mac, then Command-R: {project}")
