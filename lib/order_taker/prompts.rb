module OrderTaker
  # Builds the text fed to agent runs. The daemon posts each run's final
  # output verbatim as a GitHub comment, and prompts must say so.
  module Prompts
    module_function

    def preamble(repo, number)
      <<~TXT
        You are working headlessly inside order_taker, a daemon that relays GitHub
        issue/PR conversations on #{repo} to you and posts your final message
        verbatim as a comment on #{repo}##{number}. Rules:
        - Your FINAL message is the comment body. Write it as GitHub-flavored
          markdown addressed to the human. No preamble about being an AI, no
          meta-commentary about these instructions.
        - Never post comments on #{repo}##{number} or its pull request yourself
          (via gh or otherwise); the daemon does that with your final message.
        - The human is often reading from a phone. Be concise and concrete.
      TXT
    end

    def plan(repo:, number:, events:)
      <<~TXT
        #{preamble(repo, number)}
        New activity:

        #{render_events(events)}

        Read the relevant code in this repository and reply with:
        1. Your understanding of the request and a concrete implementation plan
           (files you would touch, approach, how you would test it).
        2. Any clarifying questions whose answers would change the plan.

        Do NOT write code, create branches, or modify anything yet. The human
        will explicitly authorize implementation in a later comment.
      TXT
    end

    def resume(repo:, number:, events:)
      <<~TXT
        New activity on #{repo}##{number}:

        #{render_events(events)}

        Update your plan or answer accordingly. Reminder: your final message is
        posted verbatim as a comment; do not modify anything yet.
      TXT
    end

    def work(repo:, number:, events:, worktree:, branch:, default_branch:)
      <<~TXT
        New activity on #{repo}##{number}:

        #{render_events(events)}

        The human has authorized implementation. A worktree has been prepared
        for you at #{worktree} on branch #{branch} (based on origin/#{default_branch}).
        Work only inside that worktree, using absolute paths.

        1. Implement the plan as discussed, including tests. While iterating,
           run only focused tests (e.g. script/test_focus) for the code you
           are changing.
        2. Before opening a PR, run the repository's documented pre-PR gate
           (script/test if present, otherwise the documented suite) once in
           the worktree and get it green. Do not rerun broad suites after
           every edit; gate scripts self-skip when the tree is unchanged.
        3. Commit your work with clear messages.
        4. Push the branch: git push -u origin #{branch}
        5. Open a pull request with gh pr create, including "Closes ##{number}"
           in the PR body.

        If you cannot complete the work, do not open a PR; explain exactly what
        blocked you in your final message instead. Either way, your final
        message is posted as a comment on the issue.
      TXT
    end

    def work_resume(repo:, number:, events:, worktree:, branch:)
      <<~TXT
        New activity on #{repo}##{number} (you previously opened a PR from
        branch #{branch}, worktree #{worktree}):

        #{render_events(events)}

        Address this feedback in the same worktree, keep tests green, commit,
        and push to the same branch to update the PR. Your final message is
        posted verbatim as a comment; summarize what you changed or answer the
        questions raised.
      TXT
    end

    def render_events(events)
      events.map { |event|
        case event["type"]
        when "issue_opened"
          "### Issue opened by @#{event["author"]}: #{event["title"]}\n\n#{event["body"]}"
        when "comment"
          "### Comment by @#{event["author"]}\n\n#{event["body"]}"
        when "review_comment"
          "### Review comment by @#{event["author"]} on `#{event["path"]}`\n\n#{event["body"]}"
        when "review"
          "### Review (#{event["state"]}) by @#{event["author"]}\n\n#{event["body"]}"
        else
          "### #{event["type"]} by @#{event["author"]}\n\n#{event["body"]}"
        end
      }.join("\n\n---\n\n")
    end
  end
end
