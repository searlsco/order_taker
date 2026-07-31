# order_taker

File a GitHub issue from your phone, and a daemon on your Mac at home spins up
an agent to plan it, converse with you in the comments, and (once you say the
word) implement it in a worktree and open a PR.

order_taker runs stateful but punctuated agent sessions: nothing runs between
events, and each new comment resumes the same session with its full context
intact. Supports Claude Code and Codex.

## How it works

1. You open an issue on a watched repo. order_taker starts an agent session in
   your local clone, which reads the code, formulates a plan, and asks
   clarifying questions. Its reply is posted as an issue comment.
2. Each comment you write resumes the session. The conversation is the state;
   the daemon only routes events.
3. When a comment (or the issue body) contains your configured go word, the
   daemon prepares a git worktree and branch, and the agent implements the
   work, runs the tests, pushes, and opens a PR with `Closes #N`.
4. The PR joins the same session: PR comments, review comments, and review
   summaries all resume it, and the agent pushes updates to the same branch.
5. When the PR is merged or closed (or the issue is closed), the daemon
   mechanically removes the worktree, deletes the branch if merged, and
   archives the session. Commenting again on an archived thread revives it.

## Requirements

- macOS with the lid open (display sleep is fine; a closed lid stops launchd
  jobs by default)
- `gh` authenticated as the account that should post comments and open PRs.
  Using a bot account is strongly recommended: GitHub does not notify you
  about your own comments, so a bot account is what makes agent replies show
  up on your phone. The bot needs write access to every watched repo.
- `claude` and/or `codex` on your PATH

## Install

```sh
brew install searlsco/tap/order_taker
```

Or from a clone: `bundle install`, then run `bin/order_taker` directly.

## Setup

```sh
order_taker init      # writes an example config
$EDITOR ~/.config/order_taker/config.json
order_taker install   # installs and loads the launchd agent
```

## Config

```json
{
  "authorized_authors": ["searls", "bitsly"],
  "go_word": "roadhouse",
  "default_agent": "claude",
  "poll_interval_seconds": 60,
  "max_concurrent_runs": 2,
  "run_timeout_seconds": 3600,
  "repos": {
    "searls/example": {
      "path": "~/code/searls/example",
      "default_agent": "claude",
      "agent_args": {"claude": [], "codex": []}
    }
  }
}
```

- `authorized_authors` is the security boundary. Agents run with permission
  checks bypassed, so only activity from these handles ever reaches one.
  Comments and issues from anyone else are ignored entirely. (The daemon also
  ignores its own comments, even though the bot is listed here.)
- `go_word`: a distinctive word that authorizes implementation. Pick something
  you would never type by accident.
- Put `#claude` or `#codex` in an issue title or body to override
  `default_agent` for that thread. The choice locks when the session starts.
- `repos` points at your existing local clones, so agents see your real
  CLAUDE.md, scripts, and toolchain. Worktrees are created under
  `~/.local/state/order_taker/worktrees/` and branch off `origin/<default>`.

## Notes and caveats

- On first poll of a repo, cursors initialize to "now": pre-existing issues
  are not processed until you comment on one, which enrolls it (seeded with
  its full thread).
- An authorized comment on any thread the daemon has not seen, including PRs
  and closed issues, enrolls that thread as a session.
- Failure behavior: if an agent run dies or times out, the failure is posted
  as a comment so you can reply to retry. If the daemon restarts mid-run,
  pending events are preserved and the run repeats.
- State lives in `~/.local/state/order_taker/state.json`; daemon logs live in
  `~/.local/state/order_taker/log/`. Each agent invocation streams stdout and
  stderr to a timestamped directory under `~/.local/state/order_taker/runs/`
  alongside a `run.json` manifest with its session ID, duration, exit status,
  and timeout status.
- `order_taker status` shows watched repos and session state.
- `order_taker resume searls/lip_gloss#35` continues an existing Claude or
  Codex session interactively in your terminal. The owner may be omitted when
  only one watched repository has that name. Issue and PR numbers both resolve
  to the same session. In work phase, the terminal opens in that issue's
  worktree. GitHub events remain queued until the local session exits.

## Development

```sh
bundle install
bundle exec tldr
```
