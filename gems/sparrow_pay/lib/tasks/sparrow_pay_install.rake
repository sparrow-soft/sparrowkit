# frozen_string_literal: true

# bin/rails sparrow_pay:install
#
# A rake task wrapping the generator, so the developer types one short command.
# `sparrow_pay:install` and `sparrow_pay:install:migrations` coexist -- Rake
# allows a task and a namespace to share a name -- so this does not shadow the
# migration task Rails defines for every engine.
namespace :sparrow_pay do
  desc "Wire sparrow_pay into this application"
  task install: :environment do
    require "generators/sparrowkit/install_output"
    require "generators/sparrow_pay/install/install_generator"

    Sparrowkit::InstallOutput.run("sparrow_pay") do
      SparrowPay::Generators::InstallGenerator.start([], destination_root: Rails.root)
    end
  rescue Sparrowkit::InstallError => e
    # `abort`, not `raise` -- see the note in sparrow_auth's install task.
    abort("\n#{e.message}\nThe full log is in log/sparrowkit-install.log")
  end
end
