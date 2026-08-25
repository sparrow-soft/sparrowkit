require "rake/clean"
require "fileutils"

ROOT = __dir__
GEMS = %w[sparrow_mail sparrow_auth sparrow_pay sparrow_ui].freeze

# Explicit encoding throughout. Encoding.default_external follows the locale,
# and on a machine without LANG set a UTF-8 source file reads back as US-ASCII,
# which makes the drift comparison below fail against files that are identical.
def read(path)
  File.read(path, encoding: "UTF-8")
end

def root_version
  read(File.join(ROOT, "VERSION")).strip
end

def version_file(gem_name)
  File.join(ROOT, "gems", gem_name, "lib", gem_name, "version.rb")
end

def version_file_contents(gem_name, version)
  constant = gem_name.split("_").map(&:capitalize).join

  # Deliberately ASCII-only. Generated files get compared byte for byte by
  # version:check, and non-ASCII in generated code is a needless way for that to
  # go wrong on a machine with a different locale.
  <<~RUBY
    # frozen_string_literal: true

    # Generated from the repository root VERSION file. Do not edit by hand;
    # bump VERSION and run `rake version:sync`. All SparrowKit gems release in
    # lockstep. See docs/decisions/0007-monorepo-of-gems-with-lockstep-versioning.md
    module #{constant}
      VERSION = "#{version}"
    end
  RUBY
end

namespace :version do
  desc "Write the root VERSION into every gem's version.rb"
  task :sync do
    version = root_version
    GEMS.each do |gem_name|
      File.write(version_file(gem_name), version_file_contents(gem_name, version))
      puts "#{gem_name} -> #{version}"
    end
  end

  desc "Fail if any gem's version.rb has drifted from the root VERSION"
  task :check do
    version = root_version
    drifted = GEMS.reject do |gem_name|
      read(version_file(gem_name)) == version_file_contents(gem_name, version)
    end

    unless drifted.empty?
      abort <<~MSG
        Version drift in: #{drifted.join(", ")}
        Root VERSION is #{version}. Run `rake version:sync` and commit the result.
      MSG
    end

    puts "All gems at #{version}."
  end
end

# The licence, kept identical in five places for one reason: each gemspec names
# LICENSE.txt in its own files list, so a gem installed on its own has to carry
# the terms with it. Five copies is five chances to drift, which is exactly what
# happened -- the root file was corrected and the four gem copies were left as
# the holding notice it replaced, one that granted nothing. Buyers received only
# the copies, because template/package.rb vendors gems/ and not the root.
#
# Generated and checked rather than maintained, the same way version.rb is. The
# root file is the licence; the rest are copies a task makes.
def licence_file(gem_name = nil)
  gem_name ? File.join(ROOT, "gems", gem_name, "LICENSE.txt") : File.join(ROOT, "LICENSE.txt")
end

namespace :licence do
  desc "Copy the root LICENSE.txt into every gem"
  task :sync do
    licence = read(licence_file)
    GEMS.each do |gem_name|
      File.write(licence_file(gem_name), licence)
      puts "#{gem_name} <- LICENSE.txt"
    end
  end

  desc "Fail if any gem's LICENSE.txt has drifted from the root one"
  task :check do
    licence = read(licence_file)
    drifted = GEMS.reject { |gem_name| read(licence_file(gem_name)) == licence }

    unless drifted.empty?
      abort <<~MSG
        Licence drift in: #{drifted.join(", ")}
        The root LICENSE.txt is the licence. Run `rake licence:sync` and commit the result.
      MSG
    end

    puts "All gems carry the root licence."
  end
end

# The theme is one hand-written stylesheet compiled by Tailwind. There is no
# palette generator and nothing to keep in sync: every colour in the source is
# one of Tailwind's own, referenced by variable rather than restated.
# See docs/decisions/0021-stock-tailwind-over-a-derived-palette.md.
#
# Deliberately NOT in the default task. It needs Node, and a Ruby suite that
# cannot run without a JavaScript toolchain installed is a suite people stop
# running. gems/sparrow_ui/spec/sparrow_ui/compiled_css_spec.rb catches a
# stale build in pure Ruby instead.
namespace :ui do
  desc "Compile the console stylesheet with Tailwind (requires Node)"
  task :css do
    Dir.chdir(File.join(ROOT, "gems", "sparrow_ui")) do
      # `npx @tailwindcss/cli` alone is not enough: `@import "tailwindcss"`
      # resolves from the SOURCE FILE's directory upwards, and npx's temporary
      # install is not on that path. The package has to be installed locally.
      sh "npm install --silent --no-audit --no-fund"

      # Deleted first, because the build is otherwise not idempotent: after a
      # view is removed, a rebuild kept emitting theme variables only that view
      # had needed. The committed artifact has to be a function of the source,
      # not of what happened to be here last time.
      FileUtils.rm_f("app/assets/stylesheets/sparrow_ui/console.css")
      sh "npm run --silent build"
    end
  end

  desc "Rebuild the console stylesheet whenever a view or the theme changes"
  task :watch do
    Dir.chdir(File.join(ROOT, "gems", "sparrow_ui")) do
      sh "npm install --silent --no-audit --no-fund"

      # Not the `css` task's cleanup-then-build: this one process holds the
      # output open for the session. Run `rake ui:css` once before committing,
      # which deletes first and so cannot carry a removed view's leftovers into
      # the artifact.
      puts "Watching. The stylesheet is re-read on every page render, so a"
      puts "browser refresh is enough -- the preview host needs no restart."
      sh "npm run --silent build -- --watch"
    end
  end

  # Two commands, because they are two long-running processes and a rake task
  # that forked both would own neither: killing one would orphan the other, and
  # Tailwind's errors would land interleaved with Rails'.
  desc "Serve the console at http://127.0.0.1:4500/sparrowkit with all three panels"
  task :preview do
    # The script rather than the command it runs. It changes to the preview
    # host's directory first, and `rails server` finds an application by
    # looking in the working directory -- run from here it decides you meant
    # `rails new` and prints the generator's help, which is a confusing way to
    # be told the working directory was wrong.
    sh File.join(ROOT, "preview", "bin", "console")
  end
end

namespace :spec do
  GEMS.each do |gem_name|
    desc "Run #{gem_name}'s test suite"
    task gem_name do
      Dir.chdir(File.join(ROOT, "gems", gem_name)) do
        # with_unbundled_env, not a bare sh.
        #
        # This rake task runs under `bundle exec`, which exports BUNDLE_GEMFILE
        # pointing at the root Gemfile. A child process inherits it, and
        # bundler honours the variable over the working directory -- so
        # Dir.chdir above moves rspec but not its dependency resolution, and
        # every gem's suite silently ran against the ROOT bundle.
        #
        # That defeated the whole point. Each gem has its own Gemfile so its
        # suite resolves against its own dependencies only, which is how the
        # layering stays honest; resolving against the root bundle means a gem
        # could reach a sibling's dependency and no suite would notice.
        Bundler.with_unbundled_env { sh "bundle exec rspec" }
      end
    end
  end
end

desc "Run every gem's test suite"
task spec: GEMS.map { |g| "spec:#{g}" }

desc "Run standardrb across the repository"
task :lint do
  sh "bundle exec standardrb"
end

# The docs:* tasks were removed with the bundle model. They existed to police
# what a buyer did not receive; open source has no such line -- the repository
# is the product, and every document in it ships by definition.
task default: [
  "version:check",
  "licence:check",
  :spec,
  "spec:docs",
  "vocabulary:check",
  :lint
]
