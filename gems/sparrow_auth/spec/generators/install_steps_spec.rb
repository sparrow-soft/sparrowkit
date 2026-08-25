# frozen_string_literal: true

require "rails_helper"
require "rails/generators"
require "generators/sparrow_auth/install/install_generator"

# What `bin/rails sparrow_auth:install` actually does to a host application.
#
# The installer's whole promise is that a developer types one command instead of
# making three hand edits, so what matters is that it edits correctly and that
# running it again is harmless. "Did that work?" is the commonest reason anyone
# re-runs an installer, and one that duplicated a route on its second run would
# be one nobody dares re-run.

# Enough of a migration for the selection logic: a version, a name, and the
# filename whose engine suffix is how ours are told from anybody else's.
#
# Hoisted above the describe block: standardrb's Lint/ConstantDefinitionInBlock
# rejects a constant defined inside one, and it is not auto-fixable.
FakeMigration = Struct.new(:version, :name, :filename)

RSpec.describe "sparrow_auth:install, as a host application sees it" do
  let(:destination) { Rails.root.join("tmp/install-steps-spec") }

  before do
    FileUtils.rm_rf(destination)
    FileUtils.mkdir_p(destination.join("config"))
    File.write(destination.join("config/routes.rb"), "Rails.application.routes.draw do\nend\n")
  end

  after { FileUtils.rm_rf(destination) }

  def run
    SparrowAuth::Generators::InstallGenerator.start(
      [], destination_root: destination, shell: Thor::Shell::Basic.new
    )
  end

  def routes
    File.read(destination.join("config/routes.rb"))
  end

  def migrations
    Dir[destination.join("db/migrate/*.rb")].map { |path| File.basename(path) }
  end

  describe "the routes it writes" do
    it "mounts the auth engine" do
      run

      expect(routes).to include('mount SparrowAuth::Engine => "/auth"')
    end

    it "mounts the control panel, in development only" do
      # Nothing used to add this line. It was written down in one README, so
      # the page a developer needs FIRST was the one step they had to find and
      # perform by hand.
      run

      expect(routes).to include('mount SparrowUi::Engine => "/sparrowkit" if Rails.env.development?')
    end

    it "adds each mount once, however many times it is run" do
      3.times { run }

      expect(routes.scan("mount SparrowAuth::Engine").size).to eq(1)
      expect(routes.scan("mount SparrowUi::Engine").size).to eq(1)
    end

    it "honours a different mount point" do
      SparrowAuth::Generators::InstallGenerator.start(
        ["--mount-at=/accounts"], destination_root: destination, shell: Thor::Shell::Basic.new
      )

      expect(routes).to include('mount SparrowAuth::Engine => "/accounts"')
    end
  end

  describe "the migrations it copies" do
    it "copies every migration the engine ships" do
      run

      shipped = Dir[SparrowAuth::Engine.root.join("db/migrate/*.rb")].size

      expect(migrations.size).to eq(shipped)
      expect(shipped).to be > 0
    end

    it "tags them with the engine's name, which is how it knows to run only its own" do
      run

      expect(migrations).to all(end_with(".sparrow_auth.rb"))
    end

    it "copies nothing a second time" do
      run
      first = migrations

      run

      expect(migrations).to match_array(first)
    end

    # The copy used to go through Thor's `rake` action, which shells out to
    # `bin/rake` in the destination. Anywhere without one -- a fresh directory,
    # this spec -- it failed with a LoadError, and the generator carried on and
    # announced that the database was already up to date. Copying through
    # ActiveRecord cannot fail quietly.
    it "does not depend on a rake binary in the destination" do
      expect(File.exist?(destination.join("bin/rake"))).to be(false)

      run

      expect(migrations).not_to be_empty
    end
  end

  # The guard that keeps the specs above from touching the test database, and
  # that stops the installer migrating on behalf of a directory nobody asked
  # about.
  it "does not migrate a database for somewhere that is not this application" do
    expect_any_instance_of(ActiveRecord::MigrationContext).not_to receive(:run)

    run
  end

  # The promise the whole design rests on, tested directly rather than inferred
  # from the fact that the file copying works.
  #
  # `rails db:migrate` means "apply every pending change in this application".
  # Our tables cannot collide with a developer's -- every one is prefixed, and
  # the only tables we alter are our own -- but the risk was never collision. It
  # was scope: on an existing app, db:migrate would also run whatever migration
  # they were halfway through writing.
  describe "choosing which migrations to run" do
    let(:generator) do
      SparrowAuth::Generators::InstallGenerator.new([], [], destination_root: Rails.root)
    end

    let(:ours) { FakeMigration.new(1, "CreateSparrowAuthAccounts", "/db/migrate/1_create.sparrow_auth.rb") }
    let(:theirs) { FakeMigration.new(2, "AddColumnToWidgets", "/db/migrate/2_add_column_to_widgets.rb") }
    let(:another_engine) { FakeMigration.new(3, "AddBillingToOrganizations", "/db/migrate/3_add.sparrow_pay.rb") }

    let(:context) { instance_double(ActiveRecord::MigrationContext) }

    before do
      allow(generator).to receive(:migration_context).and_return(context)
      allow(generator).to receive(:dump_schema)
      allow(generator).to receive(:say)
      allow(generator).to receive(:say_status)
      allow(generator).to receive(:pending_migrations).and_return([ours, theirs, another_engine])
    end

    it "runs its own and leaves the developer's alone" do
      expect(context).to receive(:run).with(:up, 1).once

      generator.send(:run_our_migrations, "sparrow_auth")
    end

    it "does not run another SparrowKit module's migrations either" do
      # sparrow_pay's own installer runs those, in its own step, so that
      # installing only auth cannot quietly set up billing tables.
      expect(context).not_to receive(:run).with(:up, 3)

      allow(context).to receive(:run)
      generator.send(:run_our_migrations, "sparrow_auth")
    end

    it "tells the developer what it left pending rather than saying nothing" do
      allow(context).to receive(:run)

      expect(generator).to receive(:say).with(/1 migration of your own still pending/, any_args)

      generator.send(:run_our_migrations, "sparrow_auth")
    end

    # SparrowKit runs on PostgreSQL and SQLite -- the two databases a Rails
    # application arrives with. MySQL is refused by name: the unique-email-
    # among-live-accounts design rests on partial indexes, which MySQL does
    # not have, so an install there would be broken in a way nobody would
    # discover until a closed account blocked its address forever.
    describe "which databases it will install into" do
      it "accepts SQLite, which is what `rails new` builds unless told otherwise" do
        allow(generator).to receive(:configured_adapter).and_return("sqlite3")
        allow(context).to receive(:run)

        expect { generator.send(:run_our_migrations, "sparrow_auth") }.not_to raise_error
      end

      it "refuses MySQL by name, with the reason, before touching anything" do
        allow(generator).to receive(:configured_adapter).and_return("mysql2")

        expect { generator.send(:run_our_migrations, "sparrow_auth") }
          .to raise_error(Sparrowkit::InstallError, /mysql2/)
      end

      it "does not refuse what it cannot identify" do
        # An adapter we could not read is not evidence of the wrong database.
        # Let the reachability check and the migrations speak for themselves.
        allow(generator).to receive(:configured_adapter).and_return("")
        allow(context).to receive(:run)

        expect { generator.send(:run_our_migrations, "sparrow_auth") }.not_to raise_error
      end
    end

    it "does not count another SparrowKit module's migration as the developer's" do
      # Otherwise `sparrowkit:install` tells you that you have unfinished work
      # in the middle of the step that is about to finish it.
      allow(context).to receive(:run)

      expect(generator).not_to receive(:say).with(/2 migrations/, any_args)

      generator.send(:run_our_migrations, "sparrow_auth")
    end
  end
end
