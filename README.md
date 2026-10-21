# neodiff

A small, dependency-free Neovim diff viewer inspired by GitHub's split view.
Requires Neovim 0.10+ and Git.

```text
┌─────────────────────┬─────────────────────────────────────────┐
│ Files Changed       │ lua/app.lua                             │
│ M  lua/app.lua      │ old version        │ new version        │
│ A  README.md        │ red changes        │ green changes      │
│ D  legacy.lua       │                    │                    │
├─────────────────────┤                    │                    │
│ Timeline            │                    │                    │
│ ● working tree      │                    │                    │
│ ○ staging area      │                    │                    │
│ ○ ▸ feature         │                    │                    │
│ ● ▸ main            │                    │                    │
└─────────────────────┴────────────────────┴────────────────────┘
```

## Install locally

With lazy.nvim, add this to your plugin specs:

```lua
{
  dir = '/Users/ray/Desktop/Programs/Lua/neodiff',
  name = 'neodiff',
  cmd = { 'NeoDiff', 'NeoDiffClose' },
  opts = { sidebar_width = 32, stack_height = 5 },
}
```

Or add this to `init.lua` without a plugin manager:

```lua
vim.opt.runtimepath:append('/Users/ray/Desktop/Programs/Lua/neodiff')
require('neodiff').setup({ sidebar_width = 32, stack_height = 5 })
```

To try it without modifying your configuration, run from a Git repository:

```sh
nvim --cmd 'set runtimepath+=/Users/ray/Desktop/Programs/Lua/neodiff' -c 'NeoDiff main'
```

## Compare

```vim
" Default branch versus working tree
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
Unchanged lines provide context; native Neovim diff highlighting and synchronized
scrolling show where they differ. The left pane is the base; the right pane is the
target. Comparisons use the exact selected snapshots, including branch tips.
Buffers are read-only. Selecting an entry never checks out a branch or stages files.

## Timeline

The Timeline starts with working tree and staging area, followed by local branches.
Initially the working tree is the target and the detected default branch is the
base. Both selected entries have filled circles.

- Press `Enter` to choose the target and `b` to choose the base. Both sides can be
  a branch, commit, staging area, or working tree. Pressing `Enter` below the
  current base changes the base instead, keeping the target selected. Pressing
  `Enter` on the base leaves the comparison unchanged. Pressing `b` on the target
  swaps the two sides.
- Press `o` on a branch to expand or collapse its commits. Commits appear newest
  first, with hashes and subjects, and support the same `Enter` and `b` keys.
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

| Key | Action |
| --- | --- |
| `j` / `k`, then `Enter` | Select a file in the sidebar |
| `Enter` in Timeline | Select target, or change base when below it |
| `b` in Timeline | Select base |
| `o` in Timeline | Expand / collapse branch commits |
| `r` | Refresh the current comparison |
| `]f` / `[f` | Next / previous file from any panel |
| `]c` / `[c` | Next / previous diff hunk from any panel, continuing into the next / previous file |
| `Tab` | Cycle panels |
| `Ctrl-w` + direction | Standard Neovim window navigation |
| `q` / `:NeoDiffClose` | Close the viewer tab |

Each invocation opens an independent tab. Press `r` to refresh after saving or committing.
Renamed files compare their old and new paths. Binary files, submodules, and files
larger than 2 MiB show a placeholder. Git commands have a ten-second timeout and run synchronously, so
very large repositories may briefly pause the interface.

## Test

From this directory:

```sh
nvim --headless -u NONE -l tests/smoke.lua
```

The tests create a temporary repository, exercise comparisons and viewer windows,
and remove the temporary repository afterward.
