# frozen_string_literal: true

# bin/rails sparrowkit:install
#
# Runs the installer for every SparrowKit module that is actually in the
# application's Gemfile, and nothing for the ones that are not.
#
# Lives in sparrow_ui because installing is a development-time activity and
# sparrow_ui is the development-group gem that provides the control panel every
# installer points at. A developer who wants one module without the console can
# still run that module's own install task.
#
# Order matters: sparrow_auth owns the organizations table and sparrow_pay adds
# billing columns to it, so billing has to go second or its migration has
# nothing to alter.
SPARROWKIT_MODULES = [
  ["SparrowAuth", "sparrow_auth"],
  ["SparrowMail", "sparrow_mail"],
  ["SparrowPay", "sparrow_pay"]
].freeze

namespace :sparrowkit do
  desc "Wire every installed SparrowKit module into this application"
  task install: :environment do
    require "generators/sparrowkit/install_output"

    # Said before the modules run, because each of them asks. It decides who
    # prints the closing notes: this task's summary, rather than each module
    # printing its own in the middle of the sequence.
    Sparrowkit::InstallOutput.umbrella!

    installed = SPARROWKIT_MODULES.select { |constant, _task| Object.const_defined?(constant) }

    if installed.empty?
      # Not an error. An application can perfectly well have sparrow_ui alone,
      # and telling somebody what to add beats failing at them.
      puts "No SparrowKit modules are installed."
      puts "Add sparrow_auth, sparrow_mail or sparrow_pay to your Gemfile, then run this again."
      next
    end

    # Each module task prints its own heading and confirmation, and captures
    # everything in between to log/sparrowkit-install.log -- so this loop adds
    # nothing to the terminal and the three read as one sequence.
    #
    # A failing module aborts, which ends the run here rather than carrying on
    # to the next one and finishing with a summary that would not be true.
    installed.each { |_constant, name| Rake::Task["#{name}:install"].invoke }

    Sparrowkit::InstallOutput.summary
  end
end
