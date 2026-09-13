#!/usr/bin/env python3
"""Self-check for render-ci.py.  Run: python3 vps/shared/test_render_ci.py

The case that matters is the LAST one: an unset secret must fail the deploy
rather than render an empty string. That is the whole reason this script exists
instead of envsubst, which happily substitutes blanks.
"""
import pathlib
import re
import subprocess
import sys
import tempfile

SCRIPT = pathlib.Path(__file__).with_name("render-ci.py")


def run(files, env, out):
    """Build a fake stack with the given ci/ files, render it, return CompletedProcess."""
    stack = pathlib.Path(tempfile.mkdtemp())
    for rel, text in files.items():
        p = stack / "ci" / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")
    return subprocess.run(
        [sys.executable, str(SCRIPT), str(stack), str(out)],
        capture_output=True, text=True, env={**env, "PATH": ""},
    )


out = pathlib.Path(tempfile.mkdtemp())
r = run({".env.n8n": "USER=@@N8N_DB_USER@@\nPORT=5678\n"}, {"N8N_DB_USER": "bob"}, out)
assert r.returncode == 0, r.stderr
assert (out / ".env.n8n").read_text() == "USER=bob\nPORT=5678\n"

# Nested paths keep their shape: ci/credentials/sa-key.json -> credentials/sa-key.json
out = pathlib.Path(tempfile.mkdtemp())
r = run({"credentials/sa-key.json": "@@SA@@"}, {"SA": '{"type":"service_account"}'}, out)
assert r.returncode == 0, r.stderr
assert (out / "credentials" / "sa-key.json").read_text() == '{"type":"service_account"}'

# A $ in a bcrypt hash must survive verbatim -- this is exactly what the old
# printf/base64 path and dex's own entrypoint both mangled.
out = pathlib.Path(tempfile.mkdtemp())
r = run({"dex.yaml": 'hash: "@@H@@"'}, {"H": "$2y$10$abc$def"}, out)
assert r.returncode == 0, r.stderr
assert (out / "dex.yaml").read_text() == 'hash: "$2y$10$abc$def"'

# A stack with no ci/ directory is not an error -- most stacks have none.
out = pathlib.Path(tempfile.mkdtemp())
stack = pathlib.Path(tempfile.mkdtemp())
r = subprocess.run([sys.executable, str(SCRIPT), str(stack), str(out)],
                   capture_output=True, text=True)
assert r.returncode == 0, r.stderr
assert not list(out.iterdir())

# THE ONE THAT MATTERS: unset and empty secrets both fail loudly, and the message
# names the variable and the file, because that is what you need at 3am.
for env in ({}, {"N8N_DB_PASSWORD": ""}):
    out = pathlib.Path(tempfile.mkdtemp())
    r = run({".env.db-n8n": "PASSWORD=@@N8N_DB_PASSWORD@@\n"}, env, out)
    assert r.returncode == 1, f"expected failure, got {r.returncode}"
    assert "N8N_DB_PASSWORD" in r.stderr and ".env.db-n8n" in r.stderr, r.stderr

# The monitoring agent's real template (#23). An agent with a blank token starts happily and
# ships nothing, so every one of its markers must fail the deploy when missing.
real = SCRIPT.parents[2] / "vps" / "bpvps2" / "stacks" / "monitoring"
markers = sorted(set(re.findall(r"@@([A-Z0-9_]+)@@", (real / "ci" / "env.ci").read_text())))
assert "GRAFANA_CLOUD_API_TOKEN" in markers, markers
full = {m: "x" for m in markers}
r = subprocess.run([sys.executable, str(SCRIPT), str(real), tempfile.mkdtemp()],
                   capture_output=True, text=True, env={**full, "PATH": ""})
assert r.returncode == 0, r.stderr
for m in markers:
    r = subprocess.run([sys.executable, str(SCRIPT), str(real), tempfile.mkdtemp()],
                       capture_output=True, text=True, env={**full, m: "", "PATH": ""})
    assert r.returncode == 1 and m in r.stderr, f"blank {m} should fail the deploy: {r.stderr}"

print("render-ci.py: all checks passed")
