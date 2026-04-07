"""SessionStart hook: verify CC_Sync workspace environment before starting work."""
import json
import shutil
import sys
sys.stdout.reconfigure(encoding="utf-8")
from pathlib import Path

project_root = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(project_root / "lib"))
try:
    import handoff  # noqa: E402 — path must be set first
except ImportError:
    handoff = None

issues = []

# 1. Python version
if sys.version_info < (3, 10):
    issues.append("Python version {} is below 3.10".format(sys.version.split()[0]))

# 2-3. Required CLI tools
for tool, msg in [("git", "git not found in PATH"), ("gh", "gh CLI not found in PATH")]:
    if not shutil.which(tool):
        issues.append(msg)

# 4. Machine name check
try:
    raw = (project_root / ".machine-name").read_text(encoding="utf-8").strip()
    if not raw:
        raise ValueError("empty file")
    machine_name = raw
except (FileNotFoundError, OSError, ValueError):
    machine_name = None
    issues.append(
        "`.machine-name` not found or empty. "
        "Tell the user to run /sync — step [5/6] will interactively prompt for a device name. "
        "Do NOT suggest manual commands or guess the device name."
    )

# 5. Handoff task check (uses shared lib/handoff.py)
if handoff:
    targets = []
    if machine_name:
        targets.append(machine_name)
    targets.append("ANY")
    try:
        text = handoff.read_file(str(project_root / "HANDOFF.md"))
        pending = handoff.get_pending_tasks(text, *targets)
        if pending:
            task_blocks = "\n\n".join(f"[{t}]:\n{body}" for t, body in pending)
            issues.append(
                f"HANDOFF: Pending tasks for this machine. "
                f"Display the following tasks to the user now:\n{task_blocks}"
            )
    except (FileNotFoundError, OSError):
        pass

if issues:
    msg = "Environment issues:\n" + "\n".join("- " + i for i in issues)
    print(json.dumps({"systemMessage": msg}))
