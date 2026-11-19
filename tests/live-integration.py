"""Exercise Neovim terminal windows and live typing against an isolated desk build."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


def main():
    command = json.loads(os.environ.get("MDMAID_DESK_COMMAND", '["mdmaid-desk"]'))
    if not isinstance(command, list) or not command or not all(isinstance(value, str) for value in command):
        raise SystemExit("MDMAID_DESK_COMMAND must be a JSON argv list")
    with tempfile.TemporaryDirectory(prefix="mdmaid-nvim-live-") as temporary:
        root = Path(temporary).resolve()
        (root / "source.md").write_text("# Saved source\n", encoding="utf-8")
        env = dict(os.environ, XDG_STATE_HOME=str(root / "state"),
                   MDMAID_NVIM_TEST_ROOT=str(root), MDMAID_DESK_COMMAND=json.dumps(command))

        def run(argv):
            result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=90,
                                    cwd=Path(__file__).resolve().parent.parent)
            output = re.sub(r"([?&]token=)[^\s&]+", r"\1[redacted]", result.stdout + result.stderr)
            if result.returncode:
                raise AssertionError(output)
            return output

        try:
            run(command + ["daemon", "start", "--port", "0"])
            print(run(["nvim", "--headless", "-u", "NONE", "-i", "NONE", "-l", "tests/live-integration.lua"]))
            start = "lua vim.api.nvim_create_autocmd('VimEnter',{once=true,callback=function() vim.defer_fn(function() dofile('tests/scroll-integration.lua') end,50) end})"
            arguments = ["nvim", "--headless", "-i", "NONE"]
            if os.environ.get("MDMAID_NVIM_REAL_CONFIG") != "1":
                arguments += ["-u", "NONE"]
            print(run(arguments + ["-c", start]))
        finally:
            run(command + ["daemon", "stop"])


if __name__ == "__main__":
    main()
