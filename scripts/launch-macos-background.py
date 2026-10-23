#!/usr/bin/env python3
"""Launch an installed app hidden in the current user's existing GUI session."""
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import time
import uuid

app = Path(sys.argv[1]).resolve()
if not (app / "Contents/Info.plist").is_file():
    raise SystemExit("Expected an installed app bundle.")
domain = f"gui/{os.getuid()}"
subprocess.run(["launchctl", "print", domain], check=True, stdout=subprocess.DEVNULL)
label = "local.app-install.hidden-launch." + uuid.uuid4().hex
with tempfile.TemporaryDirectory(prefix="app-hidden-launch-") as staging:
    plist = Path(staging) / "launch.plist"
    plist.write_bytes(plistlib.dumps({
        "Label": label,
        "ProgramArguments": ["/usr/bin/open", "-g", "-j", "-a", str(app)],
        "RunAtLoad": True,
    }))
    subprocess.run(["launchctl", "bootstrap", domain, str(plist)], check=True)
    try:
        for _ in range(100):
            status = subprocess.check_output(["launchctl", "print", domain + "/" + label], text=True)
            result = re.search(r"last exit code = (-?\d+)(?:\s|$)", status)
            if result:
                if int(result.group(1)) != 0:
                    raise RuntimeError("The background launch failed with exit code " + result.group(1))
                break
            time.sleep(0.1)
        else:
            raise RuntimeError("The background launch did not finish within ten seconds.")
    finally:
        subprocess.run(["launchctl", "bootout", domain + "/" + label], check=True)
print("Requested a hidden app launch from the existing GUI login.")
