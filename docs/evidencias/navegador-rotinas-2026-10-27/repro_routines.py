"""Test existing routine helpers with synthetic inputs only. Never invoke their network or sender paths."""
import contextlib
import datetime as dt
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace

HERE = Path(__file__).resolve().parent
WORK = Path.home() / "Documents/Projetos/AcessosFit-Brain/skills/whatsapp/scripts/puxar.py"
ANALYZER = Path.home() / "Orbs/LP AcessosFit/Rotinas/analisa.py"
records = []
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("routine_peek_investigation", WORK)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
now = dt.datetime.now(dt.timezone.utc)


def peek(label, fresh, messages):
    commands = []

    def fake_run(args, timeout=None):
        commands.append(args)
        if args[1] == "doctor":
            stamp = now - dt.timedelta(seconds=10 if fresh else 600)
            payload = dict(success=True, data=dict(authenticated=True,
                           store=dict(last_activity_at=stamp.isoformat()), connection_state="synthetic"))
        elif args[1:3] == ["messages", "list"]:
            payload = dict(success=True, data=dict(messages=messages))
        else:
            raise AssertionError("unexpected command; no real subprocess permitted")
        return SimpleNamespace(returncode=0, stdout=json.dumps(payload))

    def forbidden(*args, **kwargs):
        raise AssertionError("summary must not fetch per-chat context or save the sweep marker")

    module.run = fake_run
    module.contexts_for = forbidden
    module.save_marker = forbidden
    module.load_marker = lambda: (now - dt.timedelta(hours=1)).isoformat()
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        code = module.main(["--peek", "--summary", "--json"])
    payload = json.loads(buffer.getvalue())
    data = payload["data"]
    assert not data["marker_updated"] and data["summary"] and not data["continuous_reception_confirmed"]
    assert data["sync_recent_observed"] is fresh
    record = dict(label=label, timestamp_utc=dt.datetime.now(dt.timezone.utc).isoformat(),
                  command=["puxar.main (all external calls replaced by synthetic stubs)", "--peek", "--summary", "--json"],
                  simulated_cli_calls=commands, exit_code=code, stdout=buffer.getvalue(), stderr="")
    records.append(record)
    return payload


peek("fresh empty queue", True, [])
stale = peek("stale empty queue", False, [])
assert stale["success"] is True and not stale["data"]["pending"]
old = dict(ChatJID="fixture@s.whatsapp.net", ChatName="Synthetic fixture", MsgID="synthetic-old",
           Timestamp=(now-dt.timedelta(days=1)).isoformat(), FromMe=False, Text="Synthetic pending request")
pending = peek("old unresolved queue item before sweep marker", True, [old])
assert len(pending["data"]["pending"]) == 1 and not pending["data"]["pending"][0]["new"]

base = dict(cf_client="198.51.100.10", time="2026-10-26T10:00:00Z", status=200, method="GET", path="/", ua="Mozilla/5.0")
cases = [
    ("ordinary health read", [base], False),
    ("single curl of homepage", [dict(base, ua="curl/8.0")], True),
    ("three create POSTs hours apart", [dict(base, method="POST", path="/comprar/api/create",
                                           time=f"2026-10-26T{hour}:00:00Z") for hour in ("10", "11", "12")], True),
    ("spoofed crawler with one secret probe", [dict(base, path="/.env", status=404, ua="Googlebot/2.1")], False),
]
for label, rows, expected_candidate in cases:
    fixture = HERE / (label.replace(" ", "-") + ".jsonl")
    fixture.write_text("".join(json.dumps(r) + "\n" for r in rows))
    command = [sys.executable, str(ANALYZER), str(fixture)]
    stamp = dt.datetime.now(dt.timezone.utc).isoformat()
    p = subprocess.run(command, capture_output=True, text=True, timeout=10)
    assert p.returncode == 0 and bool(p.stdout.strip()) is expected_candidate
    records.append(dict(label=label, timestamp_utc=stamp, command=command,
                        exit_code=p.returncode, stdout=p.stdout, stderr=p.stderr))

result = dict(timestamp_utc=dt.datetime.now(dt.timezone.utc).isoformat(),
              source_sha256={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in (WORK, ANALYZER)},
              records=records)
(HERE / "routines-raw.json").write_text(json.dumps(result, ensure_ascii=False, indent=2)+"\n")
print("7 synthetic cases passed; stale success and old backlog reproduced; analyzer emitted two out-of-policy candidates and missed a crawler probe.")
