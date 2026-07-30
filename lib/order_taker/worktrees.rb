require "fileutils"
require "open3"

module OrderTaker
  # Mechanical worktree lifecycle: the daemon (not the agent) creates and
  # removes worktrees so state stays deterministic.
  module Worktrees
    GitError = Class.new(Error)

    DIR = File.join(State::DIR, "worktrees")

    def self.prepare(clone_path, repo, number, dir: DIR)
      branch = "order-taker/issue-#{number}"
      path = File.join(dir, "#{repo.tr("/", "-")}-#{number}")
      return {"path" => path, "branch" => branch, "default_branch" => default_branch(clone_path)} if Dir.exist?(path)

      FileUtils.mkdir_p(dir)
      git(clone_path, "fetch", "origin", "--prune")
      base = default_branch(clone_path)
      if git?(clone_path, "rev-parse", "--verify", "refs/heads/#{branch}")
        git(clone_path, "worktree", "add", path, branch)
      else
        git(clone_path, "worktree", "add", "-b", branch, path, "origin/#{base}")
      end
      {"path" => path, "branch" => branch, "default_branch" => base}
    end

    def self.cleanup(clone_path, worktree_path, branch, merged:)
      git(clone_path, "worktree", "remove", "--force", worktree_path) if worktree_path && Dir.exist?(worktree_path)
      git(clone_path, "branch", "-D", branch) if merged && branch && git?(clone_path, "rev-parse", "--verify", "refs/heads/#{branch}")
    end

    def self.default_branch(clone_path)
      out, status = Open3.capture2("git", "-C", clone_path, "symbolic-ref", "refs/remotes/origin/HEAD", err: File::NULL)
      return out.strip.delete_prefix("refs/remotes/origin/") if status.success?
      %w[main master].find { |name| git?(clone_path, "rev-parse", "--verify", "origin/#{name}") } ||
        raise(GitError, "Could not determine default branch for #{clone_path}")
    end

    def self.git(clone_path, *args)
      out, err, status = Open3.capture3("git", "-C", clone_path, *args)
      raise GitError, "git #{args.join(" ")} failed in #{clone_path}: #{err.strip}" unless status.success?
      out
    end

    def self.git?(clone_path, *args)
      _, status = Open3.capture2e("git", "-C", clone_path, *args)
      status.success?
    end
  end
end
