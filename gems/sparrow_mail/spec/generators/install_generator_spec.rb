# frozen_string_literal: true

require "rails_helper"
require "rails/generators"
require "generators/sparrow_mail/install/install_generator"

# What `bin/rails sparrow_mail:install` does to a host application.
#
# Less than the other two, and deliberately. This gem owns no tables and no
# routes; the only thing it needs that a gem cannot do for itself is telling
# ActionMailer which delivery method to use.
RSpec.describe "sparrow_mail:install" do
  let(:destination) { Rails.root.join("tmp/mail-install-spec") }

  let(:application_rb) do
    <<~RUBY
      require_relative "boot"
      require "rails/all"

      module Dummy
        class Application < Rails::Application
          config.load_defaults 8.0
        end
      end
    RUBY
  end

  before do
    FileUtils.rm_rf(destination)
    FileUtils.mkdir_p(destination.join("config"))
    File.write(destination.join("config/routes.rb"), "Rails.application.routes.draw do\nend\n")
    File.write(destination.join("config/application.rb"), application_rb)
  end

  after { FileUtils.rm_rf(destination) }

  def run
    SparrowMail::Generators::InstallGenerator.start(
      [], destination_root: destination, shell: Thor::Shell::Basic.new
    )
  end

  def application_config
    File.read(destination.join("config/application.rb"))
  end

  def routes
    File.read(destination.join("config/routes.rb"))
  end

  it "points ActionMailer at sparrow_mail" do
    run

    expect(application_config).to include("config.action_mailer.delivery_method = :sparrow_mail")
  end

  it "says where the provider and its key are set" do
    run

    expect(application_config).to include("/sparrowkit/mail")
  end

  it "sets the delivery method once, however many times it is run" do
    3.times { run }

    expect(application_config.scan("delivery_method = :sparrow_mail").size).to eq(1)
  end

  it "mounts the control panel, so installing mail alone still reaches it" do
    run

    expect(routes).to include("mount SparrowUi::Engine")
  end

  # The whole reason the old generator was deleted. It wrote a settings file
  # that config/initializers evaluated AFTER credentials were read, so it
  # silently overwrote whatever the control panel had just saved -- resetting
  # the provider to the test adapter and sending every message nowhere.
  it "writes no settings file" do
    run

    expect(Dir[destination.join("config/initializers/*.rb")]).to be_empty
  end

  it "creates no migrations, because this gem owns no tables" do
    run

    expect(Dir[destination.join("db/migrate/*.rb")]).to be_empty
  end
end
