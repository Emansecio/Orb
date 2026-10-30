"""Probe the pinned browser using a new profile, private sockets and a local fixture only."""
import datetime as dt
import json
import os
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = Path.home() / "Library/Application Support/Orb/navegador"
BINARY = ROOT / "bin/agent-browser"
CHROME = next((ROOT / "chrome").glob("*/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"))
fixture = HERE / "snapshot-fixture.html"
fixture.write_text('''<!doctype html><html lang="en"><title>Orb token investigation</title>
<div role="toolbar" aria-label="Campaign tools">
<div role="button" tabindex="0" aria-label="Save campaign">Save campaign</div>
<div role="button" tabindex="0" aria-label="Cancel campaign">Cancel campaign</div></div>
<div id="layout" role="none" style="display:contents"><h1>Campaign metrics</h1>
<a href="#report">Daily report</a><span id="metric">Clicks 10</span></div>
<div id="hidden" aria-hidden="true"><button>Hidden action</button></div>
<section id="results"></section></html>''')
records = []
with tempfile.TemporaryDirectory(prefix="orb-tok-", dir="/tmp") as temp:
    work = Path(temp)
    (work / "config.json").write_text("{}\n")
    (work / "sockets").mkdir()
    env = {k: v for k, v in os.environ.items() if not k.upper().startswith("AGENT_BROWSER_")}
    env["AGENT_BROWSER_SOCKET_DIR"] = str(work / "sockets")
    base = [str(BINARY), "--session", "tok", "--json", "--config", str(work / "config.json")]

    def run(label, args):
        command = base + args
        timestamp = dt.datetime.now(dt.timezone.utc).isoformat()
        try:
            p = subprocess.run(command, cwd=work, env=env, text=True, capture_output=True, timeout=45)
            record = dict(label=label, timestamp_utc=timestamp, command=command,
                          exit_code=p.returncode, stdout=p.stdout, stderr=p.stderr)
        except subprocess.TimeoutExpired as exc:
            record = dict(label=label, timestamp_utc=timestamp, command=command, exit_code=None,
                          stdout=str(exc.stdout or ""), stderr="timeout after 45 seconds")
        records.append(record)
        (HERE / "browser-raw.json").write_text(json.dumps(records, ensure_ascii=False, indent=2) + "\n")
        try:
            obj = json.loads(record["stdout"])
        except ValueError:
            obj = {}
        return obj

    try:
        run("version", ["--version"])
        opened = run("open isolated local fixture", ["--executable-path", str(CHROME), "--profile", str(work / "profile"), "open", fixture.as_uri()])
        if not opened.get("success"):
            raise RuntimeError("isolated fixture failed to open; see browser-raw.json")
        for label, args in [
            ("full interactive", ["snapshot", "--interactive", "--urls", "--compact"]),
            ("missing HTML button", ["snapshot", "--interactive", "--urls", "--compact", "--selector", "button"]),
            ("missing main", ["snapshot", "--interactive", "--urls", "--compact", "--selector", "main"]),
            ("ARIA button selector", ["snapshot", "--interactive", "--urls", "--compact", "--selector", "[role=button]"]),
            ("layout without AX node", ["snapshot", "--interactive", "--urls", "--compact", "--selector", "#layout"]),
            ("hidden DOM node without AX node", ["snapshot", "--interactive", "--urls", "--compact", "--selector", "#hidden"]),
            ("virtual ref is not a DOM attribute", ["snapshot", "--interactive", "--urls", "--compact", "--selector", "[ref=e3]"]),
            ("missing dialog", ["snapshot", "--interactive", "--urls", "--compact", "--selector", "[role=dialog]"]),
            ("full after selector errors", ["snapshot", "--interactive", "--urls", "--compact"]),
            ("delta baseline", ["snapshot", "--interactive", "--urls", "--compact", "--delta"]),
            ("delta unchanged", ["snapshot", "--interactive", "--urls", "--compact", "--delta"]),
            ("change fixture", ["eval", "document.getElementById('results').innerHTML='<button>Export report</button>';true"]),
            ("delta after change", ["snapshot", "--interactive", "--urls", "--compact", "--delta"]),
            ("full after change", ["snapshot", "--interactive", "--urls", "--compact"]),
        ]:
            run(label, args)
    finally:
        run("close isolated session", ["close"])

print(json.dumps([dict(label=r["label"], exit_code=r["exit_code"],
                       stdout_chars=len(r["stdout"])) for r in records], indent=2))
