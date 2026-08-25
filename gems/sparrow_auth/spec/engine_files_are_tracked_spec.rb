# frozen_string_literal: true

require "rails_helper"
require "open3"

# Every file the engine ships must actually be in the repository.
#
# This exists because of a failure that gave no signal at all. `.gitignore` had
# an unanchored `log/`, which matches a directory called `log` at *any* depth —
# including `app/views/sparrow_auth/staff/log/`. So `git add -A` skipped the
# template, the commit succeeded, `git status` was clean, the whole suite passed
# locally, and CI failed on a missing view for a controller that plainly had one.
#
# Nothing in the ordinary run of things catches that. The suite passes locally
# precisely because the file is on disk; it is only absent where the code was
# checked out fresh. So the check has to ask git rather than the filesystem.
#
# It generalises beyond the one rule that caused it: any future ignore pattern
# that swallows a source file fails here, in the suite, rather than after a push.
# Where source lives. Deliberately not the whole gem: tmp/, log/ and
# spec/dummy's generated files are ignored on purpose.
SHIPPED_DIRECTORIES = %w[app console lib config db].freeze

RSpec.describe "the files this engine ships" do
  def root
    SparrowAuth::Engine.root
  end

  def ignored_files_in(directory)
    path = root.join(directory)
    return [] unless path.exist?

    # --others --ignored lists files git is deliberately not tracking.
    # --exclude-standard applies the same rules a commit would.
    out, status = Open3.capture2(
      "git", "ls-files", "--others", "--ignored", "--exclude-standard", "--directory",
      chdir: path.to_s
    )
    raise "git ls-files failed in #{path}" unless status.success?

    out.lines.map(&:strip).reject(&:empty?).map { |entry| File.join(directory, entry) }
  end

  SHIPPED_DIRECTORIES.each do |directory|
    it "tracks everything under #{directory}/" do
      ignored = ignored_files_in(directory)

      expect(ignored).to be_empty,
        "These are on disk and would not be committed:\n" \
        "  #{ignored.join("\n  ")}\n" \
        "Something in .gitignore matches them. That is how a template goes missing " \
        "in CI while the suite passes locally."
    end
  end

  # The specific rule that caused it, pinned. An unanchored directory pattern in
  # a monorepo eventually swallows something it was not written for.
  it "does not ignore directories by an unanchored name" do
    gitignore = root.join("..", "..", ".gitignore").cleanpath
    skip "no repository-level .gitignore" unless gitignore.exist?

    unanchored = gitignore.read.lines.map(&:strip).select { |line|
      next false if line.empty? || line.start_with?("#", "!", "/", "*")

      # Ends with a slash and has no other slash: a bare directory name.
      line.end_with?("/") && line.count("/") == 1
    }

    expect(unanchored).to be_empty,
      "Unanchored directory patterns match at every depth, including inside " \
      "app/views:\n  #{unanchored.join("\n  ")}\n" \
      "Anchor them with a leading slash, or spell out the paths."
  end
end
