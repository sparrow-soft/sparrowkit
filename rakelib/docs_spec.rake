# frozen_string_literal: true

# The repository's own specs: invariants that belong to no single gem.
#
# Today that is one thing -- the documentation describes the code that exists,
# and only the code that exists. It runs from the root bundle rather than a
# gem's, because it reads across all four.
namespace :spec do
  desc "Check the documentation against the code it describes"
  task :docs do
    sh "bundle exec rspec spec"
  end
end
