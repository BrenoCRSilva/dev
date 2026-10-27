# Task-agent system: survey

> **Historical snapshot.** This survey describes the system before s1-s5, at `8011d6a`. The body
> is kept as written. Changed since: every claude role runs Opus 5.5, diff-reviewer included; the
> orchestrator has no 200k auto-compact cap and gets one soft /compact line at 400k in place of
> the 120k/150k guard; a task has shared `agent`, `nvim` and `srv` windows in place of
> `nvim-<repo>`/`srv-<repo>` and `srv-1`; workers and the researcher get Haiku helper subagents;
> context clones are indexed with codegraph and read through the `context-scout` helper.

Read-only survey of today's code against the four asks. File references are relative to
`env/.config/tmux/scripts/` unless a path is shown. Nothing here is designed in depth; the
"change points" are where a change would land.

## 1. Start-up and resume

### How a session starts today

- **Orchestrator tab.** `herdr_layout` (`task-sessionizer.sh:1688-1725`) creates the task-root
  herdr workspace with `TASK_ROLE=orchestrator` and runs `agent-picker.sh` in it (`:1713-1723`).
  The picker sees `TASK_ROLE=orchestrator`, offers claude/codex only, asks the resume prompt, and
  runs `task-agent.sh --provider <p> orchestrator [--resume]` (`agent-picker.sh:98-107`).
- **Other tabs (plain picker, not used by tasks).** The same picker runs `claude -c` or `claude`
  after the same y/n prompt (`agent-picker.sh:111-119`). The research workspace gets only
  `TASK_ROLE=researcher` and no picker (`task-sessionizer.sh:1716-1718`).
- **Workers and researcher.** Never started by the picker. The dispatcher starts them through
  `task-agent.sh start worker <repo> <pane> <canonical>` or `start researcher <pane>`
  (`task-dispatch.py:189-201` for the researcher, `:207-225` for relaunch). No `--resume` is passed,
  so they always start fresh.

### Where the "resume? yes/no" prompt comes from

It is the script's own prompt: `ask_resume` in `agent-picker.sh:83-92` (single keypress,
default no, text "resume last <agent> session? [y/N]"). It runs for the orchestrator tab on every
task open. It is not Claude Code's prompt and not herdr's. The yes answer maps to
`--resume` for the orchestrator (`agent-picker.sh:102-103`), and to `claude -c` on plain tabs
(`:114`).

### How fresh vs resume is decided in task-agent.sh

- Flags are parsed at `task-agent.sh:222-229`: a trailing `--resume` sets `resume=yes`, a trailing
  `--restarted` sets `restarted=yes`.
- `agent_args` (`:352-406`) adds `--continue` for claude when `resume=yes` (`:378`). Codex gets
  `resume --last` (`:386`).
- The orchestrator's kickoff text is chosen at `:488-495`: resumed (`--resume`), restarted
  (`--restarted`, text names the AGENTS.md / digest / wakes steps and re-asking of Decisions,
  `:492`), or fresh.
- The sessionizer's own repair hints still print `--resume` for workers and the researcher
  (`task-sessionizer.sh:1244-1245`); the dispatcher does not pass it.

### Folder trust

- Claude: `trust_pane_cwd` (`task-agent.sh:446-484`) writes
  `projects[<cwd>].hasTrustDialogAccepted = true` in `~/.claude.json`, using the pane's real cwd
  from herdr (`pane_cwd`, `:410-415`). It is called only in the non-orchestrator branch
  (`:499-500`).
- Codex: `codex_trust_args` (`:423-439`) passes an inline `projects={...}` override, only for
  worker and researcher (`:388-391`).
- **Missed roles.** The orchestrator branch (`:488-498`) never calls `trust_pane_cwd`. Its launch
  cwd is the task root, so that folder can still show the trust prompt. The orchestrator restart
  path (`--restarted`) goes through the same branch, so it misses trust too.
- **Not launch folders, so no trust needed.** The researcher launches in `<root>/research`, which
  is trusted. `research/context/<repo>` clones are never a launch cwd. Workers launch in their
  worktree, which is trusted (`:500`).

### `task-agent.sh restart orchestrator`

- `restart_orchestrator` (`task-agent.sh:151-173`) needs `HERDR_PANE_ID` and must run from the
  orchestrator's own pane (`:154-160`). It builds `task-agent.sh --provider <p> orchestrator --restarted`
  (`:161`) and starts `finish_restart` detached via `--restart-finish` (`:170`, dispatch at `:206-207`).
- `finish_restart` (`:176-192`) polls until the orchestrator is `idle`, calls `stop_agent no
  orchestrator` (sends `/exit`), then types the fresh launch into the same pane with `herdr pane run`
  (`:182`). Gives up after 10 minutes.
- What the fresh session reads: AGENTS.md, `task-dispatch.py digest`, `wakes`, and the open
  Decisions it re-asks. The fresh session does not get a handoff file; the kickoff text (`:492`) is
  its only pointer. Nothing carries the old context.

### Change points (ask 1)

- `agent-picker.sh:83-119`: the y/n prompt for orchestrator tabs (`:102`), and the non-orchestrator
  path. Removing the prompt means choosing `--resume` automatically when a session exists (needs
  a check for an existing session first; `--continue` with none fails or starts fresh).
- `task-agent.sh:488-500`: add the trust call for the orchestrator (task root) before the launch, or
  move `trust_pane_cwd` above the role split.
- `task-agent.sh:222-229` and `:378`: the flag and `--continue` plumbing, if the resume decision moves
  into the script.
- `task-sessionizer.sh:1244-1245`: repair text that names `--resume`.

## 2. Models and context

### MODEL / EFFORT table

`task-agent.sh:34-41`

| provider:role | model | effort |
|---|---|---|
| claude:orchestrator | claude-opus-5-5 | medium |
| claude:worker | claude-haiku-5-5 | high |
| claude:researcher | claude-haiku-5-5 | high |
| codex:orchestrator | gpt-6-astra | medium |
| codex:worker | gpt-6-luna | high |
| codex:researcher | gpt-6-luna | medium |

Applied at `:367` (`--model`, `--effort`). The worktree plan (`AGENTS.md` template,
`task-sessionizer.sh:554`) repeats the table as text, so it has a second place to update.

Subagents (`task-roles/subagents/`, copied by `write_claude_files`, `task-sessionizer.sh:892-906`):
`status-reader.md` model `haiku`; `diff-reviewer.md` model `sonnet`. They are copied only when
absent, so an existing task keeps its old copy.

### Context-limit assumptions

- **Context guard.** `task-context-guard.py`: `checkpoint = 120_000` and `restart = 150_000`
  (`:46-47`, env overrides `TASK_CONTEXT_CHECKPOINT` / `TASK_CONTEXT_RESTART`). It reads the prompt
  size from the newest main-thread assistant turn in the transcript tail (`prompt_tokens`, `:23`).
  It runs as a `UserPromptSubmit` and `PostToolUse` hook for the orchestrator only
  (`task-roles/orchestrator.claude-settings.json`).
- **Auto-compact backstop.** `ORCHESTRATOR_ENV` (`task-agent.sh:61`) sets
  `CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000`, `CLAUDE_CODE_PROMPT_CACHE_TTL=1h`,
  `ENABLE_CLAUDEAI_MCP_SERVERS=false`. Applied only for claude orchestrator launches (`:498`).
- **Plan budgets (workers).** `task_plan.py:15`: `DEFAULTS["budget"] = {turns: 60, prompt_k: 90}`.
  The per-attempt values are stored in `attempts.budget_turns` / `budget_prompt_k`
  (`task_state.py:30`, `:257-267`).
- **Enforcement.** `over_budget` (`task-dispatch.py:649-654`) compares the worker's self-reported
  `context_estimate_k` (`task-roles/report.schema.json:70`) with `prompt_k`. It is called from
  `evaluate` (`:684-700`) and runs before any jev clearance. The orchestrator is not a node, so
  no budget applies to it.
- **Worker self-report.** `task-roles/worker.md:74` and `researcher.md:90-94` ask agents to estimate
  their context and write `restart suggested` at about 90k.
- **Orchestrator restart flow.** Guard line at 120k (checkpoint, a reminder) and 150k (restart
  request). `orchestrator.md:115-129` tells the orchestrator to run `task-agent.sh restart
  orchestrator` from its last action of the turn, and that workers/researcher use `session =
  "fresh"` by default.

### Spend tracking

`task-spend.py` has list prices per model (`PRICES`, `:63-80`). `claude-opus-5-5` has one tier at
$4 input / $20 output per million. `claude-haiku-5-5` has a 100k-upto tier. Costs are list-price
estimates; the status line labels them `est` (`task-statusline.sh:25`).

### Change points (ask 2)

- `task-agent.sh:34-41`: the MODEL/EFFORT tables (orchestrator to Opus with a 1M window, workers
  and researcher unchanged or moved).
- `task-agent.sh:61`: `CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000` is the cap that would stop a 1M
  window. Remove or raise it together with the model change.
- `task-context-guard.py:46-47`: thresholds, and the 120k / 150k text at the top (`:4-5`), if
  native compaction replaces the guard.
- `task_plan.py:15` and `task-dispatch.py:649-654`: worker budgets. Opus is not affected; this matters
  only if the worker model stays at 100k-tier pricing.
- `task-spend.py:63-80`: add or confirm the Opus 5.5 price tier if the model string or window size
  changes.
- `orchestrator.md:115-129` and `task-roles/orchestrator.claude-settings.json`: the restart
  instruction and the guard hooks.

## 3. Panes, tabs and windows

### What is created per task

`ensure_task_runtime` (`task-sessionizer.sh:1632-1647`) creates the tmux session (`:1637`) and calls
`ensure_task_layout` (`:1595-1630`) and `herdr_layout` (`:1688-1725`).

tmux windows (`ensure_task_layout`):
- `agent` at the task root (`:1604`).
- For each worktree, in order: `nvim-<repo>` running `nvim .` (`:1608-1609`, `:1590-1591`).
- For each worktree again: `srv-<repo>`, a shell window (`:1611-1614`).
- Windows are swapped into this order (`:1619-1625`). Any other window is kept behind them.

herdr workspaces (`herdr_layout`): one per label, created only when missing (`:1706-1724`):
- task root (label = task name), with `TASK_ROLE=orchestrator` and the agent picker (`:1713-1723`);
- one per worker worktree (label = repo name), pane at a shell prompt;
- `research` (label), with `TASK_ROLE=researcher` (`:1716-1717`).

So a 4-worker task has 1 + 4 + 4 = 9 tmux windows and 6 herdr workspaces.

### Dependencies on pane ids, labels and folder names

- `ensure_worker_order` (`task-sessionizer.sh:110-130`) reads existing `nvim-*` window names to
  rebuild the worker order when `.task-worker-order` is missing.
- `dispatch_hooks` (`:329-342`) sends hooks to `srv-<repo>` and falls back to `srv-1`.
- `quit_nvim_window` (`:1409-1416`) and the close and remove paths (`:1470-1482`) use `nvim-<repo>` and
  `srv-<repo>` names.
- `preserve_window_name` (`:1562-1569`) renames windows that clash.
- `task-agent.sh:340-343` requires the pane cwd basename to equal the folder name
  (`worker` folder = repo name, `research`).
- `ensure_researcher` (`task-dispatch.py:189-201`) finds the researcher pane by `cwd == <root>/research`.
- `herdr_layout` (`:1707`) and `herdr_announce` (`:1672`) use workspace labels.
- `task-assignment.sh:76-89` names the agent from the folder (`worker-<repo>` or `researcher`).

### Subagent install

`write_claude_files` (`task-sessionizer.sh:892-906`) symlinks `CLAUDE.md` to `AGENTS.md`, writes
`.claude/settings.json` if absent, and copies `task-roles/subagents/*.md` into `.claude/agents/`
if absent. Existing tasks keep the copies they have.

### Change points (ask 3)

- `task-sessionizer.sh:1604-1615`: stop creating `nvim-<repo>` and `srv-<repo>` per worktree (keep one
  `agent` window, and a shared `srv` or none). Then fix the dependents below.
- `task-sessionizer.sh:110-130` (`ensure_worker_order`), `:329-342` (`dispatch_hooks`, the `srv-1`
  fallback), `:1409-1416` (`quit_nvim_window`), `:1470-1482` (close): they read or close the windows
  by name.
- `task-sessionizer.sh:1688-1725` (`herdr_layout`): one workspace per worker, plus `research`. Could move
  the workers into one workspace with several panes, but `task-agent.sh:340-343` and the dispatcher's
  pane lookup assume a pane per folder.
- New agent kinds (Haiku fan-out): `task-roles/` gets a new prompt and settings file, and
  `task-agent.sh:34-42` (`MODEL`, `EFFORT`, `PROMPT`) gets the role. Subagents go in
  `task-roles/subagents/` (copied on create only).

## 4. Context repos

### How a context repo is added and refreshed

- Records: `.task-context.tsv` in the task root (`task_context_file`, `:225`; `task_contexts`, `:227-232`).
- Add: `add_context` (`:685-715`) validates the canonical path under `~/Projects` or `~/Work`
  (`canonical_repo`, `:672`), records it, and clones.
- Clone: `clone_context` (`:357-368`) runs `git clone --local <canonical> research/context/<name>`.
  This only reads the canonical checkout.
- Refresh: `refresh_context` / `refresh_context_clone` (`:382-434`) fetch and fast-forward the clone.
  No codegraph sync runs here; the researcher's own docs say to run `codegraph sync` after a refresh
  (`task-roles/researcher.md:25`).
- Sync: `sync_contexts` (`:1146-1161`) recreates missing clones.
- Promote: `promote_context` (`:1005-1024`) removes the clone and record, and adds the repo to
  `.task-worker-order`. Then `add` creates a worktree.
- Demote and remove: `demote_repo` (`:1421`), `remove_context` (`:718-734`).
- Close checks: `context_clone_issues` (`:438-452`) reports custom data or dirty state in
  `research/context/`.

### Codegraph on context repos

- Canonical context repos are never indexed. Workers never see them.
- Clones are indexed by the **researcher's** SessionStart hook: `task-assignment.sh:76-89` collects
  every `research/context/*` folder that is its own git top level. `index_batch` (`:56-72`) runs
  `codegraph init -y` in each. The hook runs in the background; the agent starts without waiting.
- Workers skip clones (`:82`).
- `CODEGRAPH_NO_WATCH` is deliberately unset for these runs (`:58`) because `init` installs git hooks;
  a clone has its own `.git`, so it does not touch the canonical repo's hooks.

### Where a user sees the list of context repos

- `AGENTS.md` only: `write_agents_md` (`task-sessionizer.sh:541-568`) and `sync_repo_modes`
  (`:569`) write a "### Context only (read-only)" section (`:632-636`) and the Repo modes table.
- The task "Manage" list (`task-sessionizer.sh:2173`, `manage <task>`) and the mode picker's CONTEXT row
  (`:2438`) act on them; this survey did not check whether Manage lists them.
- `task-statusline.sh` shows only the orchestrator: `orchestrator | model | cost est | ctx N% |
  cache state, hit, misses (ttl)` (`:31`). It shows no repo or context information.
- `task-sessionizer.sh list` (`:27`) shows tasks, state and RAM only.

### Change points (ask 4)

- `task-sessionizer.sh:227-232`, `:685-715`, `:1005-1024`: the `.task-context.tsv` format and the
  add or promote paths.
- `task-sessionizer.sh:357-434`: clone and refresh. Add a `codegraph sync` step here if the
  researcher should not have to run it.
- `task-assignment.sh:76-89`: which folders get indexed.
- `task-statusline.sh:37`: add a context count or list (it reads the orchestrator's JSON only, so
  the count has to come from a file such as `.task-context.tsv`).
- `task-sessionizer.sh:541-568`: the AGENTS.md Context section.

## Risks and coupling

- **Window names.** `nvim-<repo>`, `srv-<repo>` and the `srv-1` fallback are read by name in
  `ensure_worker_order`, `dispatch_hooks`, `quit_nvim_window`, close and `preserve_window_name`.
  Removing or renaming them breaks ordering, hook dispatch and nvim quit (which can keep an unsaved
  nvim open).
- **Folder names are identities.** The agent name comes from the folder (`worker-<repo>`,
  `research`), and `task-agent.sh:340-343`, `task-assignment.sh:76-89`, `ensure_researcher`
  (`task-dispatch.py:189-201`) and the reports and hooks folders depend on it. Renaming `research` or
  moving worktrees breaks all of them.
- **Trust keys are absolute cwds.** `~/.claude.json` is keyed by the real path (`realpath`, `:410-415`).
  A new folder layout (e.g. a symlinked root) needs its own trust entry.
- **Model change is three places.** The MODEL table (`task-agent.sh:34-41`), the auto-compact window
  (`:61`) and the guard thresholds (`task-context-guard.py:46-47`) must change together. A 1M window
  with the 200k cap or the 120k/150k guard gives a half-applied result.
- **Restart depends on kickoff text.** `task-agent.sh:492` names AGENTS.md, digest and wakes. Changing
  the orchestrator's start-up steps means changing this string and `orchestrator.md`.
- **Resume prompt is shared.** `ask_resume` is also used for plain (non-task) tabs. Changing it for
  tasks only needs a `TASK_ROLE` check.
- **Codex and Claude share ARGS building.** `agent_args` (`:352-406`) and the codex branches (`:386-404`)
  change together. Edits to one provider must be checked against the other.
- **Subagents are copied once.** Changing `task-roles/subagents/*.md` does not reach existing tasks
  (`write_claude_files` skips existing files).
- **Budgets are self-reported.** `context_estimate_k` comes from the worker's own estimate
  (`report.schema.json:70`). A wrong estimate changes stops and wakes but cannot be checked here.
- **Sessionizer repair text.** `task-sessionizer.sh:1244-1245` prints `--resume` and `start` commands
  that must match the `task-agent.sh` argument parser.
