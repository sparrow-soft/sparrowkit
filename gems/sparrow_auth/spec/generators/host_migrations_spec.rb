# frozen_string_literal: true

require "rails_helper"
require "rails/generators"
require "generators/sparrow_auth/install/install_generator"

# A host must end up with exactly ONE copy of each migration.
#
# Engines reach a host's schema one of two ways: the engine adds its own
# db/migrate to the host's migration paths, or the migrations are copied into
# the host. This gem copies -- that is what `install:migrations` does, and it is
# what lets a host edit, reorder or squash migrations it now owns.
#
# It also did the other one. An initializer added the engine's db/migrate to
# the host's paths, so every migration existed twice: once as the copy, once
# from the gem. `bin/rails db:migrate` -- the most ordinary command in Rails --
# died on DuplicateMigrationNameError in every application that installed this.
#
# Nothing in this repository could see it. The dummy applications migrate from
# explicit engine paths and never consult a host's configured ones, so the whole
# suite passed while the product was unusable. It was found by installing into a
# real application and typing db:migrate.
RSpec.describe "migrations, as a host application sees them" do
  let(:destination) { Rails.root.join("tmp/host-migrations-spec") }

  before do
    FileUtils.rm_rf(destination)
    FileUtils.mkdir_p(destination.join("config"))
    File.write(destination.join("config/routes.rb"), "Rails.application.routes.draw do\nend\n")
  end

  after { FileUtils.rm_rf(destination) }

  it "does not add the engine's own db/migrate to a host's migration paths" do
    # The check is on the engine rather than on a booted host, because booting a
    # second application inside this suite is not possible. An initializer that
    # pushes onto `app.config.paths["db/migrate"]` is the shape being refused.
    engine_source = File.read(SparrowAuth::Engine.instance_method(:initialize).source_location.first)

    expect(engine_source).not_to match(/app\.config\.paths\["db\/migrate"\]\s*<</),
      "sparrow_auth's engine adds its migration path to the host. It also copies " \
      "its migrations in, so a host would have each one twice and db:migrate would " \
      "raise DuplicateMigrationNameError. Pick one; this gem copies."
  end

  it "copies each migration exactly once" do
    SparrowAuth::Generators::InstallGenerator.start(
      [], destination_root: destination, shell: Thor::Shell::Basic.new
    )

    # Class names, which is what Rails collides on -- not filenames, which carry
    # a fresh timestamp on every copy and would look unique either way.
    names = Dir[destination.join("db/migrate/*.rb")].map { |path|
      File.basename(path).sub(/\A\d+_/, "").sub(/\.sparrow_auth\.rb\z/, "")
    }

    expect(names).not_to be_empty
    expect(names).to eq(names.uniq)
  end
end
