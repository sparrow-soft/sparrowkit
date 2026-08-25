# frozen_string_literal: true

# bin/rails sparrow_auth:install
#
# A rake task wrapping the generator, so the developer types one short command
# instead of `bin/rails generate sparrow_auth:install`. Both work; this is the
# one the documentation gives.
#
# `sparrow_auth:install` and `sparrow_auth:install:migrations` can coexist --
# Rake allows a task and a namespace to share a name -- which matters because
# Rails defines the second for every engine and we do not want to shadow it.
namespace :sparrow_auth do
  desc "Wire sparrow_auth into this application"
  task install: :environment do
    require "generators/sparrowkit/install_output"
    require "generators/sparrow_auth/install/install_generator"

    Sparrowkit::InstallOutput.run("sparrow_auth") do
      SparrowAuth::Generators::InstallGenerator.start([], destination_root: Rails.root)
    end

    # An application with nobody in it gets somebody to sign in as; one that
    # already has people is left alone. See SparrowAuth::Seed.during_install.
    SparrowAuth::Seed.during_install.each { |line| Sparrowkit::InstallOutput.note(line) }

    # Under `sparrowkit:install` the closing summary prints these, at the end,
    # where somebody is looking. Run on its own there is no summary, so this
    # task prints them itself.
    Sparrowkit::InstallOutput.print_notes unless Sparrowkit::InstallOutput.umbrella?
  rescue Sparrowkit::InstallError => e
    # `abort`, not `raise`. The message is written for a person and already says
    # what to do next; a stack trace under it buries that instruction in two
    # hundred lines of Rails internals. abort also exits non-zero, which is what
    # stops `sparrowkit:install` carrying on to the next module and finishing
    # with "SparrowKit is installed" underneath an explanation of why it is not.
    abort("\n#{e.message}\nThe full log is in log/sparrowkit-install.log")
  end
end
