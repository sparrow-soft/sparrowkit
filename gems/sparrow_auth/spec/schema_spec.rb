# frozen_string_literal: true

require "rails_helper"
require "open3"

# What the migrations actually built, asked of a database rather than read.
#
# This replaces a spec that regex-scanned the migration files for their declared
# Rails version and never opened anything. That check was worth keeping and is
# still here, at the bottom -- but on its own it let a set of migrations through
# that could not be rolled back at all, because nothing ever tried.
#
# The suite has already run every migration by the time this file loads (see
# rails_helper), so the assertions below are about the schema those migrations
# produced on the adapter this run is using. The one thing that cannot be asked
# of the test database is rollback, since rolling back means dropping every
# table in it -- that runs in its own process against its own database.
RSpec.describe "the schema" do
  def connection
    ActiveRecord::Base.connection
  end

  # The engine's own tables. The dummy application has some of its own, and this
  # is a spec about what sparrow_auth ships.
  def engine_tables
    connection.tables.select { |name| name.start_with?("sparrow_auth_") }.sort
  end

  # Every table this gem is supposed to create, and nothing else.
  #
  # Written out rather than counted, because a count passes when one table is
  # added and another removed -- which is exactly the shape of the mistake a
  # squash makes.
  def expected_tables
    %w[
      sparrow_auth_account_active_session_keys
      sparrow_auth_account_identities
      sparrow_auth_account_password_hashes
      sparrow_auth_account_verification_keys
      sparrow_auth_account_webauthn_keys
      sparrow_auth_account_webauthn_user_ids
      sparrow_auth_accounts
      sparrow_auth_auth_events
      sparrow_auth_email_auth_keys
      sparrow_auth_invitations
      sparrow_auth_memberships
      sparrow_auth_organizations
      sparrow_auth_otp_codes
    ]
  end

  # Thirteen, and the thirteenth is created whether or not the application uses
  # it. Sign-in links are chosen on the control panel at runtime, so a table
  # that only existed for applications that had chosen them would turn a
  # settings-page toggle into a pending migration nobody was told about.
  it "creates exactly the thirteen tables the engine describes" do
    expect(engine_tables).to eq(expected_tables)
  end

  # A foreign key with no index means the referenced row cannot be deleted
  # without scanning the referencing table, and every one of these cascades on
  # delete -- so closing one account scans every table that points at accounts.
  #
  # "Indexed" means some index starts with that column, not that an index exists
  # for it alone: a composite leading with the column serves the same lookup,
  # which is why memberships has no separate index on account_id. Primary keys
  # count for the same reason.
  it "indexes every foreign key" do
    unindexed = engine_tables.flat_map { |table|
      leading = connection.indexes(table).map { |index| Array(index.columns).first }
      leading += Array(connection.primary_keys(table)).first(1)

      connection.foreign_keys(table).reject { |fk| leading.include?(fk.column) }
        .map { |fk| "#{table}.#{fk.column} -> #{fk.to_table}" }
    }

    expect(unindexed).to be_empty,
      "these foreign keys have no index leading with their column:\n  #{unindexed.join("\n  ")}"
  end

  # A single-column index whose column already leads a composite index on the
  # same table is dead weight: it can serve no query the composite cannot, and
  # it is paid for on every write.
  #
  # Partial indexes are exempt from being the *shadowed* one, because a unique
  # partial index enforces a rule rather than answering a question -- the plain
  # index on accounts.email and the partial unique one above it are both needed
  # and neither replaces the other.
  it "carries no index shadowed by a composite with the same leading column" do
    shadowed = engine_tables.flat_map { |table|
      indexes = connection.indexes(table)
      composites = indexes.select { |index| Array(index.columns).size > 1 }

      indexes.select { |index|
        Array(index.columns).size == 1 && index.where.nil? && !index.unique &&
          composites.any? { |c| Array(c.columns).first == Array(index.columns).first }
      }.map { |index| "#{table}.#{index.name}" }
    }

    expect(shadowed).to be_empty,
      "these indexes are already covered by a composite that leads with the same column:\n  #{shadowed.join("\n  ")}"
  end

  describe "the indexes that carry a rule" do
    def index(table, name)
      connection.indexes(table).find { |i| i.name == name }
    end

    it "keeps one live account per address, and lets a closed one free the address" do
      live = index("sparrow_auth_accounts", "index_sparrow_auth_accounts_on_email_live")

      expect(live).to be_present
      expect(live.unique).to be(true)
      expect(live.where).to be_present
    end

    # The sign-in path. Account.find_by_email names no status, so the partial
    # index above cannot serve it and without this one every sign-in
    # sequentially scans the accounts table.
    it "can look an address up without naming a status" do
      plain = index("sparrow_auth_accounts", "index_sparrow_auth_accounts_on_email")

      expect(plain).to be_present
      expect(plain.where).to be_nil
      expect(Array(plain.columns)).to eq(["email"])
    end

    # One live invitation per address per organization, said as two indexes over
    # disjoint sets of rows: PostgreSQL treats NULLs in a unique index as
    # distinct from one another, so a single (email, organization_id) index
    # would exempt every invitation naming no organization from the rule.
    #
    # The alternative spellings both cost something this does not -- NULLS NOT
    # DISTINCT needs PostgreSQL 15, and an expression index over COALESCE cannot
    # be used for an ordinary lookup.
    it "keeps one live invitation per address per organization" do
      scoped = index("sparrow_auth_invitations", "index_sparrow_auth_invitations_on_email_and_org_pending")

      expect(scoped).to be_present
      expect(scoped.unique).to be(true)
      expect(Array(scoped.columns)).to eq(%w[email organization_id])
    end

    it "keeps one live invitation per address when none names an organization" do
      unscoped = index("sparrow_auth_invitations", "index_sparrow_auth_invitations_on_email_pending_no_org")

      expect(unscoped).to be_present
      expect(unscoped.unique).to be(true)
      expect(Array(unscoped.columns)).to eq(["email"])
    end

    # What sparrow_auth:prune filters on. Without it, the first prune of a table
    # nobody has pruned reads every row of it.
    it "can find expired sign-in codes" do
      expect(index("sparrow_auth_otp_codes", "index_sparrow_auth_otp_codes_on_expires_at")).to be_present
    end
  end

  describe "the constraints" do
    def constraint_names(table)
      connection.check_constraints(table).map(&:name)
    rescue NotImplementedError
      []
    end

    it "refuses an account status that is not one of the three" do
      expect(constraint_names("sparrow_auth_accounts"))
        .to include("sparrow_auth_accounts_status_id_check")
    end

    it "refuses a half-accepted invitation, and a role in no organization" do
      expect(constraint_names("sparrow_auth_invitations")).to include(
        "sparrow_auth_invitations_accepted_together_check",
        "sparrow_auth_invitations_role_needs_organization"
      )
    end

    # Deliberately absent. A constraint listing role names can only hold the
    # roles that existed the day it was written, so an application declaring one
    # of its own would fail at the moment somebody was given the role rather
    # than at the moment it was declared. SparrowAuth::Membership enforces this
    # instead, and fails closed on a value it does not recognise.
    it "does not list the role names in the memberships table" do
      expect(constraint_names("sparrow_auth_memberships")).to be_empty
    end
  end

  # The one thing the test database cannot be asked, because asking it means
  # dropping every table in it. Its own process, its own database.
  #
  # This is not decoration. The set this replaced could not roll back at all: a
  # remove_index with no :column raised partway through `db:rollback`, after
  # three later migrations had already reverted, leaving a database that was
  # neither schema.
  it "migrates all the way up, all the way down, and up again" do
    script = File.expand_path("scripts/migrate_up_and_down.rb", __dir__)

    unless ENV["DB"] == "sqlite"
      # Ignoring failure: it already existing is the ordinary case.
      system("createdb", ENV.fetch("SPARROW_AUTH_SMOKE_DB", "sparrow_auth_smoke"),
        out: File::NULL, err: File::NULL)
    end

    output, status = Open3.capture2e(
      {"RAILS_ENV" => "smoke"}, RbConfig.ruby, script,
      chdir: SparrowAuth::Engine.root.to_s
    )

    expect(status).to be_success, "the migrations do not survive a round trip:\n\n#{output}"
    expect(output).to include("OK")
  end

  # Kept from the spec this replaces, and still the cheapest check here.
  #
  # `ActiveRecord::Migration[8.1]` is not a version number, it is a demand:
  # Rails raises `Unknown migration version "8.1"` on any Rails that has never
  # heard of it. A migration written on the newest Rails and shipped in a gem
  # whose gemspec admits an older one cannot run at all for somebody on that
  # older Rails -- and it fails at install time, on their first command.
  #
  # The floor is read from the gemspec below rather than written here, so this
  # follows when the gemspec moves. Nothing else in this repository could catch
  # the drift, because every dummy application runs the newest Rails. Four
  # migrations had drifted once and were found only by installing the bundle
  # into a real application on the floor version by hand.
  describe "the Rails version each migration demands" do
    def gemspec_rails_floor
      spec = Gem::Specification.load(SparrowAuth::Engine.root.join("sparrow_auth.gemspec").to_s)
      rails = spec.dependencies.find { |dependency| dependency.name == "rails" }
      floor = rails.requirement.requirements.find { |operator, _| operator == ">=" }.last

      "#{floor.segments[0]}.#{floor.segments[1]}"
    end

    def migrations
      Dir[SparrowAuth::Engine.root.join("db/migrate/*.rb")]
    end

    it "is never newer than the oldest Rails the gemspec supports" do
      floor = gemspec_rails_floor

      offenders = migrations.filter_map { |path|
        declared = File.read(path)[/ActiveRecord::Migration\[([\d.]+)\]/, 1]
        next if declared.nil?
        next if Gem::Version.new(declared) <= Gem::Version.new(floor)

        "#{File.basename(path)} declares [#{declared}]"
      }

      expect(offenders).to be_empty, <<~MSG
        These migrations cannot run on Rails #{floor}, which this gem's gemspec promises to support:

          #{offenders.join("\n  ")}

        Rails raises "Unknown migration version" rather than degrading, so somebody on
        #{floor} cannot install at all. Declare ActiveRecord::Migration[#{floor}] unless the
        migration genuinely needs newer behaviour -- in which case raise the gemspec floor
        instead, and say so.
      MSG
    end

    it "is checking migrations that exist, rather than passing because it found none" do
      expect(migrations).not_to be_empty
    end
  end
end
