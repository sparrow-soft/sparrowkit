# frozen_string_literal: true

module SparrowAuth
  # What Rodauth's own pages render through.
  #
  # SparrowKit ships no end-user pages, and this is not one -- it is a render
  # target. The templates come from rodauth-rails, the same defaults any Rodauth
  # application starts with, and `bin/rails generate rodauth:views` copies them
  # into your app to own and restyle.
  #
  # It inherits ActionController::Base rather than your ApplicationController on
  # purpose. An auth page that breaks because the application added a
  # before_action requiring a signed-in user is a locked door with the key
  # inside. Point `rails_controller` at your own controller in the initializer
  # when you want your filters on these pages as well as your layout.
  class RodauthController < ActionController::Base
    # YOUR layout. These are your pages.
    #
    # rodauth-rails renders its own templates with `layout: true`, which means
    # "the controller's default" -- so this controller has to resolve one, and
    # `layout false` is not an option however much it would suit the rule that
    # SparrowKit ships no pages. Every Rails application has
    # app/views/layouts/application.html.erb from the moment `rails new` runs.
    #
    # The engine used to ship its own instead: three hundred lines of markup and
    # a colour vocabulary, so a bare application had a styled sign-in for free.
    # That is what this release stopped doing. It was our design on your users'
    # screens, and replacing it was the first afternoon's work.
    #
    # `bin/rails generate rodauth:views` copies the templates in so you own
    # those too, and `rails_controller` in the initializer points these pages at
    # your own controller when you want your filters on them as well.
    layout "application"
  end
end
