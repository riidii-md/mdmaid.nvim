"""Real CLI integration using a private catalog and test-owned daemon only."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from urllib.request import build_opener, ProxyHandler, Request


def run(command, env):
    result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=45)
    if result.returncode:
        detail = re.sub(r"([?&]token=)[^\s&]+", r"\1[redacted]", result.stdout + result.stderr)
        raise AssertionError(f"{command[0]} failed: {detail}")
    return result.stdout


def main():
    for executable in ("mdmaid-desk", "nvim", "git"):
        if not shutil.which(executable):
            raise SystemExit(f"Required executable not found: {executable}")
    with tempfile.TemporaryDirectory(prefix="mdmaid-nvim-integration-") as temporary:
        base = Path(temporary).resolve()
        root = base / os.environ.get("MDMAID_NVIM_TEST_PROJECT", "project with spaces")
        root.mkdir()
        fixture_name = os.environ.get("MDMAID_NVIM_TEST_NAME", "first & file.md")
        first = root / fixture_name
        first.write_text("# Initial live document\n", encoding="utf-8")
        (root / "second.md").write_text("# Another document\n", encoding="utf-8")
        env = dict(os.environ, XDG_STATE_HOME=str(base / "state"), MDMAID_NVIM_TEST_ROOT=str(root), MDMAID_NVIM_TEST_NAME=fixture_name)
        run(["git", "init", "-q", str(root)], env)
        try:
            # Pin a dynamically chosen test port; never connect to the user's catalog.
            run(["mdmaid-desk", "daemon", "start", "--port", "0"], env)
            run(["nvim", "--headless", "-u", "NONE", "-i", "NONE", "-l", "tests/integration.lua"], env)
            original = json.loads((root / "result.json").read_text())
            descriptor = json.loads((base / "state/mdmaid.desk/daemon.json").read_text())
            origin = f"http://127.0.0.1:{descriptor['port']}"
            opener = build_opener(ProxyHandler({}))

            def request(route):
                return opener.open(Request(origin + route, headers={
                    "Authorization": "Bearer " + descriptor["token"],
                }), timeout=8)

            def render():
                with request(f"/api/v1/documents/{original['id']}/render?target=web") as response:
                    return json.load(response)["data"]

            # The service remains available after Stop and Neovim exit.
            with request("/d/" + original["id"]) as response:
                assert response.status == 200
            assert "Initial live document" in render()["content"]
            print("PASS document registration, argv paths, switching, and service lifetime")

            with request("/api/v1/events") as events:
                def next_event():
                    data = []
                    event_type = None
                    while True:
                        line = events.readline().decode().strip()
                        if not line:
                            if data:
                                return event_type, json.loads("".join(data))
                        elif line.startswith("event: "):
                            event_type = line[7:]
                        elif line.startswith("data: "):
                            data.append(line[6:])

                def wait_for_change(action):
                    # Current desk publishes generic catalog invalidations; older
                    # versions emitted document-scoped catalog events.
                    while True:
                        kind, event = next_event()
                        if kind == "catalog-invalidated" or (
                            event.get("documentId") == original["id"] and event.get("action") == action
                        ):
                            return

                next_event()  # ready
                replacement = root / "atomic-save.tmp"
                replacement.write_text("# Updated through atomic save\n", encoding="utf-8")
                replacement.replace(first)
                wait_for_change("source-changed")
                updated = render()
                assert "Updated through atomic save" in updated["content"]
                assert updated["document"]["revision"] > original["revision"]
                print("PASS live watcher event and refreshed render after atomic save")

                first.unlink()
                wait_for_change("source-missing")
                first.write_text("# Restored source\n", encoding="utf-8")
                wait_for_change("source-restored")
                assert "Restored source" in render()["content"]
                print("PASS source disappearance and restoration keep document identity")

            # A second Neovim instance must reuse workspace and document identities.
            run(["nvim", "--headless", "-u", "NONE", "-i", "NONE", "-l", "tests/integration.lua"], env)
            reopened = json.loads((root / "result.json").read_text())
            assert reopened["id"] == original["id"]
            assert reopened["other_id"] == original["other_id"]
            listing = run(["mdmaid-desk", "workspace", "list"], env)
            assert len(listing.strip().splitlines()) == 1
            print("PASS stable identity across Neovim instances and workspace reuse")
        finally:
            # This environment points only at the disposable test catalog.
            run(["mdmaid-desk", "daemon", "stop"], env)


if __name__ == "__main__":
    main()
