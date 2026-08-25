# frozen_string_literal: true

# A host application's model that names its organization and is NOT tenant
# scoped.
#
# Deliberately not `include SparrowAuth::Tenanted`. It sits beside Widget, which
# is, so the suite can show the difference: tenancy decides which rows a query
# can see, and authorization decides what the person may do. Neither substitutes
# for the other, and a model that opts out of the first still has to be guarded
# by the second.
class Project < ActiveRecord::Base
  belongs_to :organization, class_name: "SparrowAuth::Organization"
end
