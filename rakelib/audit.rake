# frozen_string_literal: true

# Known-vulnerability check against the Ruby Advisory Database.
#
# Deliberately NOT in the default gate. The gate has to run with no network --
# on a plane, in a container with no egress, at three in the morning when
# rubygems.org is down -- and a check that fetches an advisory database cannot
# promise that. CI runs this on every push and once a day, which is where a
# newly-published advisory against an unchanged lockfile actually shows up.
namespace :audit do
  desc "Check Gemfile.lock against the Ruby Advisory Database"
  task :check do
    sh "bundle exec bundle-audit check --update"
  end
end

desc "Check Gemfile.lock against the Ruby Advisory Database"
task audit: "audit:check"
