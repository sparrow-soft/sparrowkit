# frozen_string_literal: true

# Every Rails application has one of these, and Pay expects it: its own base
# class inherits from `Pay.model_parent_class`, which defaults to
# "ApplicationRecord". Without it Pay's models cannot load and its migrations
# fail — the STI one queries Pay::Customer while running.
#
# Worth a line in the README: a host that somehow lacks one has to set
# Pay.model_parent_class instead.
class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class
end
