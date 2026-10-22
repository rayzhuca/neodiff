# neodiff

A small, dependency-free Neovim diff viewer inspired by GitHub's split view.
Requires Neovim 0.10+ and Git.

```text
┌─────────────────────┬─────────────────────────────────────────┐
│ Files Changed       │ lua/app.lua                             │
│ M  app.lua  lua     │ old version        │ new version        │
│ A  README.md        │ red changes        │ green changes      │
│ D  legacy.lua       │                    │                    │
├─────────────────────┤                    │                    │
│ Timeline            │                    │                    │
│ ● working tree      │                    │                    │
│ ○ staging area      │                    │                    │
│ ● ▸ feature         │                    │                    │
│ ○ ▸ main            │                    │                    │
└─────────────────────┴────────────────────┴────────────────────┘
```

## Install locally

With lazy.nvim, add this to your plugin specs:

```lua
{
  dir = '/Users/ray/Desktop/Programs/Lua/neodiff',
  name = 'neodiff',
  cmd = { 'NeoDiff', 'NeoDiffClose' },
  opts = { sidebar_width = 32, stack_height = 8 },
}
```

Or add this to `init.lua` without a plugin manager:

```lua
vim.opt.runtimepath:append('/Users/ray/Desktop/Programs/Lua/neodiff')
require('neodiff').setup({ sidebar_width = 32, stack_height = 8 })
```

To try it without modifying your configuration, run from a Git repository:

```sh
nvim --cmd 'set runtimepath+=/Users/ray/Desktop/Programs/Lua/neodiff' -c 'NeoDiff main'
```

## Compare

```vim
" Current branch versus working tree
:NeoDiff

" Exact snapshots of main and HEAD
:NeoDiff main

" Exact snapshots of main and feature
:NeoDiff main feature

" Exact snapshots of two commits (or branches)
:NeoDiff! HEAD~3 HEAD
:NeoDiff! main feature
```

The left pane shows the old version and the right pane shows the new version.
Unchanged lines provide context; diff highlighting and synchronized
scrolling show where they differ. The viewer pads each changed block with blank
display rows so both panes scroll together, even across very large insertions.
Line numbers still refer to the original files; padding rows have no line number. The left pane is the base; the right pane is the
target. Comparisons use the exact selected snapshots, including branch tips.
Buffers are read-only. Selecting an entry never checks out a branch or stages files.

## Timeline

The Timeline starts with working tree and staging area, followed by the current branch stack.
The stack includes local ancestors and descendants of HEAD plus the detected main
branch; unrelated branches are hidden. Git ancestry is used because Git does not
store explicit branch stacks. Explicitly selected revisions remain visible.
Initially the working tree is the target and the current branch is the base
(or HEAD when detached). Both selected entries have filled circles.

- Press `Enter` to choose the target and `b` to choose the base. Both sides can be
  a branch, commit, staging area, or working tree. Pressing `Enter` below the
  current base changes the base instead, keeping the target selected. Pressing
  `Enter` on the base leaves the comparison unchanged. Pressing `b` on the target
  swaps the two sides.
- Press `o` on a branch to expand or collapse its commits. Commits appear newest
  first, with hashes and subjects, and support the same `Enter` and `b` keys.
- Double-clicking an entry works like `Enter`, except on a branch that is already
  the base or target, where it expands or collapses the branch like `o`.
- Commits load 100 at a time. Moving onto the `load more…` row (or pressing `o`
  or `Enter` on it) fetches the next page, so huge histories stay fast.
- A branch lists commits not reachable from the default base or from any other
  local branch tip it contains, so stacked branches show only their own commits.
  The default base branch, and branches already fully merged, show their full
  history. Git does not store explicit parent-branch relationships. Selected
  commits stay visible even when their branch is collapsed.
- The staging area reads the Git index. The working tree reads saved files on
  disk, including untracked files and excluding ignored untracked files. To see
  only unstaged edits, select staging as base and working tree as target. To see
  all local edits, select your current branch as base and working tree as target.

Timeline state, rendering, and its keymaps live in `lua/neodiff/panels/timeline.lua`.

## Keys

Press `?` from any panel, or click `? for help` in Timeline’s status bar, for a centered
shortcut guide. Close it with `Esc`, `q`, `?`, or `Enter`. The Timeline defaults to 8 rows; customize `stack_height` in setup.

| Key | Action |
| --- | --- |
| `j` / `k`, then `Enter` (or double-click) | Select a file in the sidebar |
| `Enter` or double-click in Timeline | Select target, or change base when below it |
| Double-click a selected branch in Timeline | Expand / collapse branch commits |
| `b` in Timeline | Select base |
| `o` in Timeline | Expand / collapse branch commits |
| `?` | Show shortcut help |
| `o` in files or a diff pane | Open the project file in a new tab |
| `gd` in a diff pane | Go to definition using the current project’s language server |
| `r` | Refresh the current comparison |
| `]f` / `[f` | Next / previous file from any panel |
| `]c` / `[c` | Next / previous diff hunk from any panel, continuing into the next / previous file |
| `Tab` | Cycle panels |
| `Ctrl-w` + direction | Standard Neovim window navigation |
| `q` / `:NeoDiffClose` | Close the viewer tab |

`gd` opens the corresponding project file in a new tab and asks its configured
language server for the definition. The diff tab stays open. Line positions are
adjusted for insertions and deletions, and renamed files use their current path.
Lookups use the current project buffer (including unsaved edits), so changed
historical code may resolve differently. Missing files and deleted lines cannot
be resolved. A language server with definition support must be configured;
NeoDiff waits briefly for it to attach when opening a file.

Each invocation opens an independent tab. Press `r` to refresh after saving or committing.
Renamed files compare their old and new paths. Binary files, submodules, and files
larger than 2 MiB show a placeholder. Git commands have a ten-second timeout and run synchronously, so
very large repositories may briefly pause the interface.

## Test

From this directory:

```sh
nvim --headless -u NONE -l tests/smoke.lua
nvim --headless -u NONE -l tests/navigation.lua
nvim --headless -u NONE -l tests/scroll.lua
```

The tests create a temporary repository, exercise comparisons and viewer windows,
and remove the temporary repository afterward.
