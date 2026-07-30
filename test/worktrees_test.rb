require "open3"

class WorktreesTest < TLDR
  def setup
    @dir = Dir.mktmpdir
    @src = File.join(@dir, "src")
    @clone = File.join(@dir, "clone")
    @worktrees = File.join(@dir, "worktrees")
    git "init", "-b", "main", @src, chdir: @dir
    File.write(File.join(@src, "README.md"), "hi")
    git "add", ".", chdir: @src
    git "commit", "-m", "initial", chdir: @src
    git "clone", @src, @clone, chdir: @dir
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_prepare_creates_worktree_and_branch_idempotently
    result = OrderTaker::Worktrees.prepare(@clone, "searls/example", 5, dir: @worktrees)

    assert_equal "order-taker/issue-5", result["branch"]
    assert_equal "main", result["default_branch"]
    assert Dir.exist?(result["path"])
    assert File.exist?(File.join(result["path"], "README.md"))

    assert_equal result, OrderTaker::Worktrees.prepare(@clone, "searls/example", 5, dir: @worktrees)
  end

  def test_cleanup_removes_worktree_and_merged_branch
    result = OrderTaker::Worktrees.prepare(@clone, "searls/example", 5, dir: @worktrees)

    OrderTaker::Worktrees.cleanup(@clone, result["path"], result["branch"], merged: true)

    refute Dir.exist?(result["path"])
    refute system("git", "-C", @clone, "rev-parse", "--verify", "refs/heads/order-taker/issue-5",
      out: File::NULL, err: File::NULL)
  end

  def test_cleanup_keeps_branch_when_not_merged
    result = OrderTaker::Worktrees.prepare(@clone, "searls/example", 5, dir: @worktrees)

    OrderTaker::Worktrees.cleanup(@clone, result["path"], result["branch"], merged: false)

    refute Dir.exist?(result["path"])
    assert system("git", "-C", @clone, "rev-parse", "--verify", "refs/heads/order-taker/issue-5",
      out: File::NULL, err: File::NULL)
  end

  private

  def git(*args, chdir:)
    out, status = Open3.capture2e(
      {"GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@example.com",
       "GIT_COMMITTER_NAME" => "t", "GIT_COMMITTER_EMAIL" => "t@example.com"},
      "git", *args, chdir: chdir
    )
    raise "git #{args.join(" ")} failed: #{out}" unless status.success?
  end
end
