# frozen_string_literal: true

# Migrates this engine's schema all the way up, all the way back down, and up
# again, against a database that starts with nothing in it.
#
# Run as its own process, from spec/schema_spec.rb, and never against the test
# database. Migrating down means dropping every table in it, and a suite whose
# examples run in random order cannot survive one example doing that -- so this
# uses the `smoke` environment, whose whole purpose is a database created from
# empty rather than reused.
#
# It prints one line per finding and exits non-zero on the first failure, so the
# spec that runs it can put the output straight in front of whoever broke it.

ENV["RAILS_ENV"] = "smoke"
require File.expand_path("../dummy/config/environment", __dir__)

ActiveRecord::Migration.verbose = false

PATH = SparrowAuth::Engine.root.join("db", "migrate").to_s
INTERNAL = %w[ar_internal_metadata schema_migrations].freeze

def connection
  ActiveRecord::Base.connection
end

def tables
  (connection.tables - INTERNAL).sort
end

def fail!(message)
  puts "FAIL: #{message}"
  exit 1
end

# Empty first, so "up" really is from nothing rather than from whatever the last
# run left.
connection.disable_referential_integrity do
  connection.tables.each { |table| connection.drop_table(table, force: :cascade) }
end
connection.schema_cache.clear!

puts "adapter: #{connection.adapter_name}"

ActiveRecord::MigrationContext.new(PATH).migrate
created = tables
fail!("migrating up created no tables") if created.empty?
puts "up: #{created.size} tables"

begin
  ActiveRecord::MigrationContext.new(PATH).migrate(0)
rescue => e
  # Named explicitly, because a rollback that dies partway is worse than one
  # that refuses to start: the migrations after the failure have already been
  # reverted, so the database is neither the old schema nor the new one.
  # Blank lines dropped: Rails pads the cause with them, and four lines of
  # padding is how the actual reason ends up off the end of the message.
  reason = e.message.lines.map(&:strip).reject(&:empty?).first(4).join(" ")
  puts "FAIL: rolling back raised #{e.class}: #{reason}"
  puts "      tables left behind: #{tables.inspect}"
  puts "      versions still applied: #{connection.select_values("SELECT version FROM schema_migrations ORDER BY version").inspect}"
  exit 1
end

left = tables
fail!("rolling back left tables behind: #{left.inspect}") unless left.empty?
puts "down: 0 tables"

ActiveRecord::MigrationContext.new(PATH).migrate
again = tables
fail!("a second run up produced a different schema: #{(created - again) | (again - created)}") unless again == created
puts "up again: #{again.size} tables"

puts "OK"
