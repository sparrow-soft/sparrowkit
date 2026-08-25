# frozen_string_literal: true

require "rails_helper"
require "rails/generators"
require "generators/sparrow_pay/install/install_generator"

# What `bin/rails sparrow_pay:install` does to a host application.
RSpec.describe "sparrow_pay:install" do
  let(:destination) { Rails.root.join("tmp/pay-install-spec") }

  before do
    FileUtils.rm_rf(destination)
    FileUtils.mkdir_p(destination.join("config"))
    File.write(destination.join("config/routes.rb"), "Rails.application.routes.draw do\nend\n")
  end

  after { FileUtils.rm_rf(destination) }

  def run(args = [])
    SparrowPay::Generators::InstallGenerator.start(
      args, destination_root: destination, shell: Thor::Shell::Basic.new
    )
  end

  def routes
    File.read(destination.join("config/routes.rb"))
  end

  it "mounts the billing engine" do
    run

    expect(routes).to include('mount SparrowPay::Engine => "/billing"')
  end

  it "mounts the control panel too, so one install is enough to reach it" do
    run

    expect(routes).to include("mount SparrowUi::Engine")
  end

  it "adds each mount once, however many times it is run" do
    3.times { run }

    expect(routes.scan("mount SparrowPay::Engine").size).to eq(1)
    expect(routes.scan("mount SparrowUi::Engine").size).to eq(1)
  end

  it "honours a different mount point" do
    run(["--mount-at=/subscription"])

    expect(routes).to include('mount SparrowPay::Engine => "/subscription"')
  end

  # This gem has no tables. It holds your processor's credentials and wires Pay
  # up; the customer and subscription rows are Pay's own, created by Pay's
  # migrations, and the installer runs those rather than shipping copies.
  #
  # It used to add three columns to sparrow_auth_organizations -- another gem's
  # table -- to mirror the plan and status Pay already knew. That is gone, and
  # with it the install-order trap where running this generator before
  # sparrow_auth left a migration with nothing to alter.
  # The whole point of the step. This gem has no tables of its own; the
  # customers and subscriptions are Pay's, and installing without them left
  # `pay_customers` missing on a completed, successful install -- so the first
  # call to organization.payment_processor raised while the panel reported the
  # module ready.
  it "installs Pay's tables, since they are the ones that matter" do
    run

    copied = Dir[destination.join("db/migrate/*.rb")].map { |path| File.basename(path) }

    expect(copied).not_to be_empty
    expect(copied).to all(end_with(".pay.rb"))
    expect(copied.join(" ")).to include("create_pay_tables")
  end

  # Every value a host would change is on the control panel, and
  # config/initializers is evaluated after credentials are read -- so a
  # generated settings file here could only ever be a second place for the same
  # value to live, silently winning over the first.
  it "writes no settings file" do
    run

    expect(Dir[destination.join("config/initializers/*.rb")]).to be_empty
  end
end
