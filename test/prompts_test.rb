class PromptsTest < TLDR
  EVENTS = [
    {"type" => "issue_opened", "author" => "searls", "title" => "Fix the widget", "body" => "It breaks"},
    {"type" => "comment", "author" => "searls", "body" => "Also add a test"},
    {"type" => "review_comment", "author" => "searls", "path" => "lib/widget.rb", "body" => "rename this"},
    {"type" => "review", "author" => "searls", "state" => "CHANGES_REQUESTED", "body" => "close, but"}
  ]

  def test_render_events_includes_each_event
    rendered = OrderTaker::Prompts.render_events(EVENTS)

    assert_includes rendered, "Issue opened by @searls: Fix the widget"
    assert_includes rendered, "Also add a test"
    assert_includes rendered, "`lib/widget.rb`"
    assert_includes rendered, "Review (CHANGES_REQUESTED)"
  end

  def test_plan_prompt_forbids_writing_code
    prompt = OrderTaker::Prompts.plan(repo: "searls/example", number: 5, events: EVENTS)

    assert_includes prompt, "searls/example#5"
    assert_includes prompt, "Do NOT write code"
  end

  def test_work_prompt_includes_worktree_branch_and_closes
    prompt = OrderTaker::Prompts.work(repo: "searls/example", number: 5, events: EVENTS,
      worktree: "/wt/example-5", branch: "order-taker/issue-5", default_branch: "main")

    assert_includes prompt, "/wt/example-5"
    assert_includes prompt, "git push -u origin order-taker/issue-5"
    assert_includes prompt, "origin/main"
    assert_includes prompt, "Closes #5"
  end

  def test_work_resume_prompt_references_existing_branch
    prompt = OrderTaker::Prompts.work_resume(repo: "searls/example", number: 5, events: EVENTS,
      worktree: "/wt/example-5", branch: "order-taker/issue-5")

    assert_includes prompt, "order-taker/issue-5"
    assert_includes prompt, "push to the same branch"
  end
end
