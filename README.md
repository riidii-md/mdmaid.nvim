# mdmaid.nvim

Open Markdown from Neovim in the shared [mdmaid.desk](https://github.com/riidii-md/mdmaid.desk) reading workspace, with Mermaid rendering and live updates while typing.

- Stable document URLs and identity across repeated opens and Neovim sessions
- Whole-document rendering in Web or a Neovim terminal buffer
- Live unsaved buffer updates, without automatically saving the source
- TUI beside the source or in the current window, with easy return to editing
- Source scrolling moves the TUI preview by document progress
- Multiple tracked files, with Telescope or `vim.ui.select`
- Failed registrations preserve the current document
- Shared catalog and service across Neovim instances

## Requirements and installation

- Neovim >= 0.9.0
- A desk CLI/service build supporting `register --live --json`, `preview --document`, and `tui --document --preview`
- Node.js >= 22 when installing desk through npm
- Telescope (optional)

Install desk:

```sh
npm install --global mdmaid-desk
```

With lazy.nvim:

```lua
{
  "riidii-md/mdmaid.nvim",
  ft = "markdown",
  config = function()
    require("mdmaid").setup()
  end,
}
```

Run `:checkhealth mdmaid` to check the CLI and client. Live buffer previews and
direct TUI opening require the companion desk changes; older desk releases can
still use saved-source Web previews with `preview.live = false`. A source build
can be selected with `mdmaid_path = { "node", "/path/to/desk/dist/cli.js" }`.
After updating desk, restart its shared daemon with the updated CLI.

## Configuration

```lua
require("mdmaid").setup({
  -- Executable, or argv prefix such as { "node", "/path/to/desk/dist/cli.js" }
  mdmaid_path = "mdmaid-desk",

  desk = {
    auto_start = true, -- Ensure the shared background daemon is running
    timeout = 15000,   -- Timeout in milliseconds for each CLI operation
    workspace = nil,  -- Optional existing desk workspace ID
    root = nil,       -- Optional workspace root; permits creating workspace above
  },

  preview = {
    target = "web",      -- Default for :MdmaidPreview; choose "tui" for Neovim
    layout = "split",    -- TUI: "split" or "replace"
    live = true,         -- Include unsaved edits
    sync_scroll = true,  -- Source → TUI scroll follow in split views
    debounce = 150,      -- Milliseconds between buffer snapshots
    auto_start = true,   -- Register/open on entering the first saved .md buffer
    open_browser = true,
    browser = nil,      -- System default, executable, or argv prefix
  },

  -- Set to false to disable all plugin keymaps
  keymaps = {
    preview = "<leader>mp",
    stop = "<leader>ms",
    files = "<leader>mf",
    add = "<leader>ma",
    web = "<leader>mw",
    tui = "<leader>mt",
    source = "<leader>me",
  },
})
```

The client reuses the deepest registered workspace containing the canonical
source path. Otherwise it registers the Git worktree root, or the document's
directory outside Git, using a deterministic ID. An existing workspace's
artifact-root policy remains in force; a rejected registration reports the desk
error. To choose a workspace explicitly, set `desk.workspace`. If that ID does
not exist, also supply `desk.root` to create it. Set only `desk.root` to select
or create a workspace for that exact root.

The default starts the shared daemon on demand; it does not install a login
service. With `desk.auto_start = false`, start the service yourself using
`mdmaid-desk daemon start` or `mdmaid-desk daemon install`.

The document must exist on disk as a `.md` file before its first registration.
After opening a preview, unsaved edits stream to a temporary desk preview
associated with the same document. The source file and shared saved-document
revision stay intact; other readers continue to see the saved source. Draft
content is held in memory and is released on Stop, buffer deletion, Neovim
exit, or disconnection. The maximum live buffer size is 2 MiB.

With `preview.live = false`, desk's source watcher supplies updates after saves,
including atomic saves. Split TUI previews follow the source’s scroll progress,
including wrapped paragraphs on Neovim 0.10+. Rendered and source lines can differ,
so scrolling follows proportional document progress. This requires a desk build
with `preview-scroll-v1` and live previews enabled. Set `preview.sync_scroll = false`
to disable it. Web and replacement views do not synchronize scrolling. There is
no cursor-to-rendered-line mapping.

## Commands and keymaps

| Command | Default keymap | Action |
| --- | --- | --- |
| `:MdmaidPreview` | `<leader>mp` (toggle) | Register the current buffer and open its document |
| `:MdmaidWeb` | `<leader>mw` | Open the whole document in Web |
| `:MdmaidOpen` | | Alias for Web opening, even with automatic browser opening disabled |
| `:MdmaidTui` | `<leader>mt` | Open the whole document in a terminal beside the source |
| `:MdmaidTui!` | | Open the terminal preview in the current window |
| `:MdmaidSource` | `<leader>me` | Return to the original Markdown buffer |
| `:MdmaidStop` | `<leader>ms` | Disconnect this Neovim client and cancel pending operations |
| `:MdmaidRestart` | | Reconnect and register the last active document |
| `:MdmaidFiles` | `<leader>mf` | Pick a tracked file and open its document |
| `:MdmaidAdd` | `<leader>ma` | Register the current file without opening the browser |
| `:MdmaidRemove` | | Remove the current file from this client's tracked list |
| `:MdmaidStatus` | | Show client state, document ID, and token-free URL |

In the TUI, `q` exits and returns to the source. `:MdmaidSource` or
`<leader>me` returns focus to editing while keeping the TUI available. In
replacement mode, the modified source buffer remains loaded; its cursor/view
is restored when returning. TUI previews show unsaved content as a reading
view; save and reopen the saved source to submit feedback or review decisions.

Telescope supports `<CR>` to open and `<C-d>` to remove a tracked file.
Stopping or exiting Neovim leaves the shared service and desk
catalog intact. Manage service lifetime with the desk CLI.

## Migration from the private preview server

The old `mdmaid serve` integration, per-instance ports, HTTP add/remove API,
temporary session files, and orphan-server cleanup have been removed. Install
`mdmaid-desk` and change any explicit `mdmaid_path = "mdmaid"` override to
`"mdmaid-desk"`.

`server.auto_start` maps to `preview.auto_start` for compatibility.
Other `server` options and `render` options are retired; configure rendering in
desk. The plugin reports a migration warning when these old tables are present.
The `require("mdmaid").server` and `require("mdmaid.server")` aliases remain
available for client operations, without server PID or port fields.

Opening/registering documents is passive and does not request workflow approval.

## Development

The regression suite runs in headless Neovim without npm dependencies:

```sh
nvim --headless -u NONE -i NONE -l tests/headless.lua
nvim --headless -u NONE -i NONE -l tests/terminal.lua
nvim --headless -u NONE -i NONE -c "lua vim.api.nvim_create_autocmd('VimEnter',{once=true,callback=function() vim.defer_fn(function() dofile('tests/scroll.lua') end,10) end})"
```

An optional real CLI/service integration check requires `mdmaid-desk`, Node.js,
Git, and Python 3. It creates an isolated temporary catalog, verifies live updates
and stable identity, and stops only its own test daemon:

```sh
python3 tests/integration.py
# Requires the companion desk build; exercises real TUI windows and unsaved edits:
MDMAID_DESK_COMMAND='["node","/path/to/desk/dist/cli.js"]' python3 tests/live-integration.py
```

## License

MIT
