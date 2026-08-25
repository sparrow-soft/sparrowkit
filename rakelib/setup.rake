# frozen_string_literal: true

# One command to make a fresh clone runnable.
#
# Each gem has its OWN Gemfile, on purpose -- see the comment on spec:<gem> --
# so its suite resolves against its own dependencies and cannot quietly reach a
# sibling's. The cost is that `bundle install` at the root is not enough: the
# gate chdirs into each gem and runs that gem's bundle, which will not exist
# until it has been installed too.
#
# Without this, a fresh clone follows the README, runs the gate, and gets
# "bundler: command not found: rspec" from a directory it was never told about.
desc "Install every bundle: the root one and each gem's own"
task :setup do
  puts "Installing the root bundle..."
  Bundler.with_unbundled_env { sh "bundle install" }

  GEMS.each do |gem_name|
    puts "Installing #{gem_name}'s bundle..."
    Dir.chdir(File.join(ROOT, "gems", gem_name)) do
      Bundler.with_unbundled_env { sh "bundle install" }
    end
  end

  puts ""
  puts "Ready. `bundle exec rake` runs everything."
end
