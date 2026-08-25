# frozen_string_literal: true

# Every real Rails application has one of these, and this dummy did not.
#
# That absence is not a detail. `rails generate sparrowkit:screens` writes
# controllers that inherit from ApplicationController, because that is what a
# generator writes into a real application -- so the generated sign-in screen
# raised `uninitialized constant ApplicationController` the moment anything
# asked the dummy to serve it, and bin/smoke could not exercise the one page a
# buyer actually signs in through.
#
# The engine's own specs did not see it: spec/generators/generated_code_runs_spec.rb
# substitutes ActionController::Base into the generated source before evaluating
# it, precisely because this constant was missing. That substitution was working
# around a gap in the harness rather than a fact about Rails applications.
#
# Deliberately bare. A dummy that adds behaviour here starts proving things about
# itself rather than about the engine.
class ApplicationController < ActionController::Base
end
