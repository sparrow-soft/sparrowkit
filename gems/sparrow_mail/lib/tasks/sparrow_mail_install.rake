# frozen_string_literal: true

# bin/rails sparrow_mail:install
#
# A rake task wrapping the generator, so the developer types one short command
# instead of `bin/rails generate sparrow_mail:install`. Both work; this is the
# one the documentation gives.
#
# `sparrow_mail:install` and `sparrow_mail:install:migrations` can coexist --
# Rake allows a task and a namespace to share a name -- which matters because
# Rails defines the second for every engine and we do not want to shadow it.
namespace :sparrow_mail do
  desc "Wire sparrow_mail into this application"
  task install: :environment do
    require "generators/sparrowkit/install_output"
    require "generators/sparrow_mail/install/install_generator"

    Sparrowkit::InstallOutput.run("sparrow_mail") do
      SparrowMail::Generators::InstallGenerator.start([], destination_root: Rails.root)
    end
  rescue Sparrowkit::InstallError => e
    # `abort`, not `raise` -- see the note in sparrow_auth's install task.
    abort("\n#{e.message}\nThe full log is in log/sparrowkit-install.log")
  end
end
