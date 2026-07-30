# order_taker plan

A Ruby daemon that watches GitHub repos and runs punctuated, resumable agent
sessions (Claude Code or Codex) in response to issue and PR activity. File an
issue from your phone, converse with the agent in comments, say the go word,
and it implements the work in a worktree and opens a PR.

## Decisions

### Stack and distribution

- Ruby, tested with the tldr test suite.
- Distributed via Homebrew through `searlsco/tap` (same pattern as the other
  formulas there); `head`/tag tarball formula with a `bin/order_taker`
  executable.
- Runs as a launchd agent installed by `order_taker install`; the Mac must be
  awake (lid open); display sleep is fine.

### Config: `~/.config/order_taker/config.json`

- `authorized_authors`: required, e.g. `["searls", "bitsly"]`. Only activity
  from these handles creates sessions or resumes them. Everything else is
  ignored (public-repo issue/comment bodies from strangers never reach an
  agent: this is the prompt-injection boundary).
- `go_word`: required string, first value `"roadhouse"`. A comment (or the
  original issue body) from an authorized author containing the go word
  triggers the work phase; the rest of that comment passes through as final
  instructions.
- `default_agent`: `"claude"` or `"codex"`. A `#claude` or `#codex` hashtag in
  the issue title or body overrides it. Agent choice locks at session start;
  later hashtags are ignored.
- `repos`: map of `owner/name` to per-repo settings, minimally `path` (the
  existing local clone, e.g. `~/code/searls/foo`); optional per-repo
  `default_agent` and extra CLI args per agent.
- `max_concurrent_runs`: default 2. Events for the same issue always
  serialize; excess runs queue in arrival order.
- `poll_interval_seconds`: default 60.
- Optional per-run timeout (default 60 minutes); on timeout or nonzero exit
  the daemon posts the failure as a comment so the conversation continues
  from the phone.

### Identity

- All GitHub access goes through the existing `gh` auth, which is the
  @bitsly bot account. Comments, branches, and PRs come from bitsly, so
  @searls gets real phone notifications for agent replies.
- At startup the daemon resolves its own login (`gh api user`) and never
  treats its own comments as triggers, even though bitsly is on the
  authorized list. bitsly needs write access to every watched repo.

### Polling (no webhooks)

- launchd keeps the daemon alive; it polls per-repo with `since` cursors:
  issues, issue comments (covers PR conversation comments), and PR review
  comments/reviews. Cursor state persists so restarts don't replay.
- All new events for one issue within a poll tick batch into a single resume
  prompt.

### Sessions

- One session per issue, spanning the issue and its eventual PR.
- Deterministic session identity derived from `owner/repo#number`:
  - Claude: `claude -p --session-id <uuidv5(...)>`, resumed with `--resume`.
  - Codex: `codex exec` with a thread name, resumed with
    `codex exec resume <thread-name>`.
- Full bypass permissions: `--dangerously-skip-permissions` /
  `--dangerously-bypass-approvals-and-sandbox`. Safety comes from the author
  allowlist, not a sandbox.
- The daemon posts each run's final output verbatim as the comment; prompts
  instruct the agent to write its reply as a GitHub comment body. The agent
  does not post comments itself.
- Sessions can start from any authorized activity, not just issue creation: a
  comment on a previously unseen issue seeds a new session with the full
  thread (handles pre-existing issues and repos added later).

### Lifecycle

1. **New issue** (authorized author): start session in the repo clone
   (read-only intent), instructions: read the repo, formulate a plan, ask
   clarifying questions. Reply posted as a comment.
2. **Conversation**: each authorized comment resumes the session. The
   session's own context is the state; the daemon keeps no conversation
   state.
3. **Go word** (`roadhouse`): resume with instructions to create a worktree
   and branch off the configured clone, implement with tests, push, and open
   a PR whose body includes `Closes #N`. Failures get commented back.
4. **PR thread**: the PR maps back to the same session; review comments and
   PR conversation resume it (agent addresses feedback in the same worktree,
   pushes again).
5. **Wind-down** (PR merged/closed, or issue closed with no PR): mechanical
   cleanup by the daemon, no agent run: `git worktree remove`, prune the
   branch if merged, archive the issue's state entry.

### State

- `~/.local/state/order_taker/state.json`: per-repo poll cursors, per-issue
  records (agent, session identity, phase, worktree path, PR number).
- Logs to `~/.local/state/order_taker/log/` (or `~/Library/Logs`), rotated
  simply.

### CLI surface

- `order_taker run`: foreground loop (what launchd invokes).
- `order_taker install` / `uninstall`: manage the launchd plist.
- `order_taker status`: show watched repos, active sessions, queue.
