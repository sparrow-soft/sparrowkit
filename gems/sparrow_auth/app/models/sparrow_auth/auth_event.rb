# frozen_string_literal: true

module SparrowAuth
  # One recorded auth action, in exactly one bucket.
  #
  # The bucket is the whole point. The application this was drawn from recorded
  # sends and verifies as
  # undifferentiated rows and counted them with overlapping queries, so
  # verifying consumed the budget for sending. A row here belongs to one bucket
  # and is counted by one budget.
  class AuthEvent < ApplicationRecord
    self.table_name = "sparrow_auth_auth_events"
  end
end
