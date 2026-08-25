# frozen_string_literal: true

module Sparrowkit
  # Raised when an install cannot finish, carrying a message written for a
  # person rather than a backtrace.
  #
  # NOT a Thor::Error, and that is the whole point. Thor rescues its own error
  # inside `Generator.start`, prints it, and returns normally -- so the rake
  # task exited 0, `sparrowkit:install` carried on to the next module, and the
  # run ended by announcing "SparrowKit is installed" underneath the explanation
  # of why it had not been. A plain StandardError propagates, and each rake task
  # turns it into `abort`, which stops everything and exits non-zero without
  # printing a stack trace at somebody.
  class InstallError < StandardError; end

  # The steps every SparrowKit installer shares.
  #
  # Lives in sparrow_mail because it is the bottom of the dependency chain --
  # sparrow_auth depends on it and sparrow_pay depends on sparrow_auth -- so
  # every module can reach this without any gem gaining a dependency it did not
  # already have.
  #
  # Mixed into each module's installer rather than run from one place, because a
  # developer installing only mail should never be told about billing.
  #
  # EVERYTHING HERE IS SAFE TO RUN TWICE. An installer that duplicated a mount
  # line or re-ran a migration on its second run is an installer nobody dares
  # re-run, and "did that actually work?" is the commonest reason to try again.
  module InstallSteps
    CONSOLE_MOUNT = %(mount SparrowUi::Engine => "/sparrowkit" if Rails.env.development?)

    # The engines whose migrations belong to SparrowKit rather than to the
    # developer. Named rather than derived, because this list has to be right in
    # an application that installed only one of them and has no constant for the
    # other two.
    OUR_ENGINES = %w[sparrow_auth sparrow_mail sparrow_pay].freeze

    private

    # Adds a line to config/routes.rb unless something like it is already there.
    #
    # Rails' own `route` action appends unconditionally, which is why running
    # the old auth installer twice left you with two mounts.
    def ensure_route(line, matching:)
      if File.exist?(routes_path) && File.read(routes_path).match?(matching)
        say_status :unchanged, "config/routes.rb already has #{line}", :yellow
        return
      end

      route line
    end

    def routes_path
      File.join(destination_root, "config", "routes.rb")
    end

    # The control panel, in development only.
    #
    # Every module's installer calls this, and the first to run wins -- which is
    # what makes `sparrowkit:install` and three separate installs end up with
    # the same routes file.
    #
    # Until now nothing added this line at all. It was written down in one
    # README, so the page a developer needs FIRST was the one step they had to
    # find and do by hand.
    #
    # Guarded on the constant because sparrow_ui is a development-group gem: an
    # application that deliberately left it out should not get a mount for an
    # engine that is not there.
    def ensure_console_mount
      return unless defined?(::SparrowUi::Engine)

      ensure_route CONSOLE_MOUNT, matching: /mount\s+SparrowUi::Engine/
    end

    # Copies this engine's migrations in, then runs ONLY those.
    #
    # NOT `rails db:migrate`, and the difference is the whole reason this exists.
    # That command means "apply every pending change in this application", so on
    # an existing app it would also run whatever migration the developer was
    # halfway through writing. Our tables cannot collide with theirs -- every one
    # is prefixed, and the only tables we alter are our own -- but the risk was
    # never collision. It was scope.
    #
    # Rails tags engine migrations as it copies them, so a file arrives as
    # `20260810120000_create_sparrow_auth_accounts.sparrow_auth.rb`. That suffix
    # is how we know which are ours, and MigrationContext#run executes exactly
    # one migration rather than everything up to it.
    def install_and_run_migrations(engine)
      copied = copy_migrations(engine)

      copied.each { |migration| say_status :create, "db/migrate/#{File.basename(migration.filename)}" }
      say_status :unchanged, "#{engine.railtie_name}'s migrations are already in db/migrate", :yellow if copied.empty?

      run_our_migrations(engine.railtie_name)
    end

    # Copies this engine's migrations into the application's db/migrate.
    #
    # Done here rather than through Thor's `rake` action, which shells out to
    # `bin/rake` in the destination directory. That failed with a LoadError the
    # first time this was tried anywhere without a `bin/rake`, and -- worse --
    # the failure did not stop the generator: it carried on and announced that
    # the database was already up to date, which was the opposite of true.
    # Calling ActiveRecord directly cannot fail silently, and it hands back
    # exactly which migrations were copied.
    def copy_migrations(engine)
      source = engine.paths["db/migrate"].expanded.first
      return [] if source.nil?

      ActiveRecord::Migration.copy(
        File.join(destination_root, "db", "migrate"),
        {engine.railtie_name => source},
        # Silent: the caller reports, and a migration already present is the
        # ordinary result of running the installer twice.
        on_skip: proc { |_name, _migration| },
        on_copy: proc { |_name, _migration| }
      ) || []
    rescue => e
      # ActiveRecord::Migration.copy READS every migration already in the host
      # application, to work out which of ours are already there. One of theirs
      # that cannot be parsed therefore aborts our installer -- with a raw stack
      # trace, from inside Rails, about a file we did not write and are not
      # about to change.
      #
      # Every other step in this installer ends in a sentence somebody can act
      # on, and this is the one that did not.
      raise Sparrowkit::InstallError, <<~MESSAGE
        Could not copy #{engine.railtie_name}'s migrations (#{e.class}).

        This usually means a migration already in db/migrate cannot be read --
        Rails looks at all of them to work out which are already installed.
        The error above names it. Nothing was written.
      MESSAGE
    end

    # Runs ONLY this engine's migrations, never the developer's.
    #
    # `rails db:migrate` means "apply every pending change in this application",
    # so on an existing app it would also run whatever migration the developer
    # was halfway through writing. Our tables cannot collide with theirs --
    # every one is prefixed, and the only tables we alter are our own -- but the
    # risk was never collision. It was scope.
    #
    # Rails tags engine migrations as it copies them, so a file arrives as
    # `20260810120000_create_sparrow_auth_accounts.sparrow_auth.rb`. That suffix
    # is how we know which are ours, and MigrationContext#run executes exactly
    # one migration rather than everything up to it.
    def run_our_migrations(engine_name)
      unless installing_into_this_application?
        say_status :skip, "not migrating: #{destination_root} is not this application", :yellow
        return
      end

      # Before reachability, because a database of the wrong kind being up is
      # no better than the right one being down. PostgreSQL and SQLite are the
      # two databases a Rails application arrives with, and both are
      # supported. MySQL is refused by name rather than left to fail later:
      # the unique-email-among-live-accounts design rests on partial indexes,
      # which MySQL does not have, so an install there would be broken in a
      # way nobody would discover until a closed account blocked its address
      # forever.
      adapter = configured_adapter
      unless adapter.empty? || adapter.match?(/\Apostg|\Asqlite/i)
        raise Sparrowkit::InstallError, <<~MSG
          SparrowKit runs on PostgreSQL or SQLite, and this application is configured
          for #{adapter}.

          Its tables use partial unique indexes -- an address is unique among accounts
          that still exist, so a closed account keeps its row without blocking the
          address forever -- and #{adapter} cannot express that. Point the application
          at PostgreSQL or SQLite in config/database.yml, then finish:

            bin/rails db:create
            bin/rails sparrowkit:install

          Nothing was migrated. The engines are mounted and the files are in place.
        MSG
      end

      # Said plainly, because the raw failure is a wall of PG::ConnectionBad
      # that buries the one instruction that fixes it. `rails new` does not
      # create the database, so this is the ordinary state of an application
      # thirty seconds old -- the commonest moment for anyone to run this.
      unless database_reachable?
        raise Sparrowkit::InstallError, <<~MSG
          SparrowKit could not reach your database, so it has not installed its tables.

          Everything else is done -- the engines are mounted and the files are in place.
          Create the database and run this again:

            bin/rails db:create
            bin/rails sparrowkit:install
        MSG
      end

      pending = pending_migrations
      ours = pending.select { |migration| migration.filename.end_with?(".#{engine_name}.rb") }

      if ours.empty?
        say_status :unchanged, "database already has #{engine_name}'s tables", :yellow
      else
        ours.each do |migration|
          say_status :migrate, migration.name
          begin
            migration_context.run(:up, migration.version)
          rescue => e
            raise Sparrowkit::InstallError, migration_failure_message(engine_name, migration, e)
          end
        end
        dump_schema
      end

      report_foreign_pending(pending)
    end

    # What a person needs to read when a migration fails, instead of two hundred
    # lines of Rails internals.
    #
    # The common case by a wide margin is a database that already holds these
    # tables from an earlier install. Migrations are copied with a fresh
    # timestamp each time, so a NEW application pointed at an OLD database sees
    # its own migrations as unapplied and tries to create tables that are
    # already there. That happens to anyone who runs the installer, hits any
    # failure, deletes the application directory and starts again -- the
    # directory goes, the database stays.
    #
    # Named for what it is rather than reported as a database error, because
    # "PG::DuplicateTable" sends somebody looking for a bug in their schema when
    # the answer is that they already have what they are trying to install.
    def migration_failure_message(engine_name, migration, error)
      already_there = error.message.match?(/already exists/i)

      return <<~MSG if already_there
        #{migration.name} could not run: this database already has that table.

        It looks like #{engine_name} was installed into #{current_database.inspect} before.
        Migrations are copied with a new timestamp each time, so a fresh application
        pointed at an older database tries to create tables that are already there.

        Either point this application at a database of its own, in config/database.yml,
        or drop the one you have and start clean:

          bin/rails db:drop db:create
          bin/rails sparrowkit:install

        Nothing was changed. Your other tables are untouched.
      MSG

      <<~MSG
        #{migration.name} failed, so #{engine_name}'s tables are not fully installed.

          #{error.message.lines.first.to_s.strip}

        Everything else is done -- the engines are mounted and the files are in place.
        Fix the cause and finish with:

          bin/rails sparrowkit:install
      MSG
    end

    def current_database
      ActiveRecord::Base.connection_pool.db_config.database
    rescue
      "this database"
    end

    # The kind of database this application is configured for, read from the
    # configuration rather than a live connection, so the wrong kind can be
    # refused before anything tries to reach it. Resolved through the pool's
    # db_config, which also answers correctly for a DATABASE_URL-only setup.
    #
    # Empty when it cannot be read, and the caller treats empty as "carry on":
    # an adapter we could not identify is not evidence of the wrong database.
    def configured_adapter
      ActiveRecord::Base.connection_pool.db_config.adapter.to_s
    rescue
      ""
    end

    # A guard, not a convenience. Migrating a database on behalf of a directory
    # that is not this application would be acting on something we were not
    # asked about -- and it is what lets the specs exercise the copying without
    # a generator reaching into the test database.
    # Asked by actually asking the database something.
    #
    # NOT `connection.active?`, which is the obvious-looking method and answers
    # a different question: whether this connection object has already been
    # opened and verified. Rails connects lazily, so on a freshly booted
    # process it is false while the database is perfectly reachable -- and the
    # first version of this check used it, which made the installer refuse to
    # install on every application that had not already run a query.
    def database_reachable?
      ActiveRecord::Base.connection_pool.with_connection { |connection| connection.select_value("SELECT 1") }
      true
    rescue
      false
    end

    def installing_into_this_application?
      defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root &&
        File.expand_path(destination_root) == File.expand_path(::Rails.root)
    end

    # Built against the directory we just copied into, NOT the connection
    # pool's own `migration_context`.
    #
    # The pool's version reads the application's configured migration paths,
    # which Rails resolves at boot and which EXCLUDE a directory that did not
    # exist then. A host with no db/migrate before installing -- which is the
    # normal state of a brand-new application that has never generated a
    # model -- would therefore find none of the migrations we had just copied,
    # run nothing, and be told the database was already up to date. That is the
    # same class of silent lie as the shell-out this method replaced, so it is
    # worth the explicit path.
    def migration_context
      pool = ActiveRecord::Base.connection_pool

      ActiveRecord::MigrationContext.new(
        [File.join(destination_root, "db", "migrate")],
        pool.schema_migration,
        pool.internal_metadata
      )
    end

    def pending_migrations
      applied = migration_context.get_all_versions
      migration_context.migrations.reject { |migration| applied.include?(migration.version) }
    end

    # Their own unrun migrations: counted, and left alone. Saying nothing would
    # be the installer deciding on their behalf that those did not matter.
    #
    # Counted from the snapshot taken BEFORE ours ran, not by asking again.
    # Re-querying happened to give the right answer only because the ones we
    # had just run were no longer pending, which is a fact about ordering
    # rather than about the question being asked.
    #
    # Another SparrowKit module's migrations are not "their own" either -- that
    # module's own installer runs those, in its own step, so counting them here
    # would tell a developer running `sparrowkit:install` that they had
    # unfinished work when the very next step was about to do it.
    def report_foreign_pending(pending)
      theirs = pending.reject { |migration|
        OUR_ENGINES.any? { |engine| migration.filename.end_with?(".#{engine}.rb") }
      }
      return if theirs.empty?

      say ""
      say "You have #{theirs.size} migration#{"s" unless theirs.size == 1} of your own still pending.", :yellow
      say "SparrowKit did not run #{(theirs.size == 1) ? "it" : "them"}. Use bin/rails db:migrate when you are ready."
    end

    # Keeps db/schema.rb honest. Running migrations through the context does not
    # dump it the way `db:migrate` does, and a schema file that disagrees with
    # the database is a bad thing to leave behind.
    def dump_schema
      ActiveRecord::Tasks::DatabaseTasks.dump_schema(
        ActiveRecord::Base.connection_pool.db_config
      )
    rescue => e
      say_status :warn, "could not update db/schema.rb (#{e.class}) -- run bin/rails db:migrate", :red
    end

    # The last thing every installer says. One destination, whichever modules
    # were installed.
    def report_console(*lines)
      say ""
      lines.each { |line| say line }
      say ""
      say "Set your API keys and settings at:", :green
      say "  bin/rails server, then http://localhost:3000/sparrowkit"
      say ""
    end
  end
end
