# frozen_string_literal: true

require "rails_helper"

# Two engines, one gem directory, and the paths that must not be shared.
#
# Rails resolves an engine's paths from its root, and both engines here resolve
# the same root. Anything the console engine also claims is therefore loaded
# TWICE, and the two known cases fail in different and equally quiet ways:
#
#   config/routes.rb  drawn twice per reload -- raises on the first named route
#                     it had already defined, while the console engine ends up
#                     with no routes at all
#   lib/tasks         `load` re-executes, and Rake APPENDS actions to a task
#                     that already exists, so the task's body runs once per
#                     load. `sparrow_auth:install` printed its whole report
#                     three times and nothing failed
#
# The second was invisible to every suite in this repository, because specs
# never load an application's rake tasks. It was found by installing the bundle
# into a real Rails application by hand. Hence a structural check: assert the
# console engine claims neither path, rather than hoping to notice again.
RSpec.describe SparrowAuth::ConsoleEngine do
  it "does not claim the rake tasks that belong to the gem" do
    expect(described_class.paths["lib/tasks"].existent).to be_empty
  end

  it "does not claim the routes file the auth engine already owns" do
    expect(described_class.paths["config/routes.rb"].existent)
      .not_to include(a_string_ending_with("config/routes.rb"))
  end

  it "still draws its own routes from the file it does own" do
    expect(described_class.paths["config/routes.rb"].existent)
      .to include(a_string_ending_with("config/console_routes.rb"))
  end

  # The third path, and the one with production stakes. The panel's controller
  # includes this engine's URL helpers in its class body, and this engine only
  # exists where sparrow_ui does -- which production is not. The auth engine
  # eager loads everything under the gem's app/ on a production boot, so the
  # panel must not live there. It lives under console/app, claimed by this
  # engine alone, so a host with sparrow_ui absent never sees the file.
  it "claims the panel's controllers from console/app" do
    expect(described_class.paths["app/controllers"].existent)
      .to include(a_string_ending_with("console/app/controllers"))
  end

  it "claims the panel's views from console/app" do
    expect(described_class.paths["app/views"].existent)
      .to include(a_string_ending_with("console/app/views"))
  end

  it "leaves nothing console-shaped under the eager-loaded app/" do
    expect(Dir[SparrowAuth::Engine.root.join("app/**/*console*").to_s]).to be_empty
  end

  # The other half: the gem's engine must still expose the tasks, or removing
  # them from the console engine would have simply deleted them.
  it "leaves the gem's engine holding them" do
    # `existent` on a globbed path returns the matched FILES, not the directory
    # they live in -- which is also why the console engine claiming this path
    # meant loading each of those files a second time.
    tasks = SparrowAuth::Engine.paths["lib/tasks"].existent.map { |path| File.basename(path) }

    expect(tasks).to include("sparrow_auth_install.rake")
  end
end
