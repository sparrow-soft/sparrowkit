# frozen_string_literal: true

# A host application's model, scoped to a tenant by including one module.
#
# That is the whole integration surface for row-based tenancy, and it is
# deliberately this small: anything an application has to remember to write on
# every model is something it will eventually forget on one.
class Widget < ActiveRecord::Base
  include SparrowAuth::Tenanted
end
