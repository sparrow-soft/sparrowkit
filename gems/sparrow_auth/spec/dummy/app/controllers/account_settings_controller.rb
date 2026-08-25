# frozen_string_literal: true

# A host application's own account page, guarded the way SparrowKit tells a
# buyer to guard one.
#
# The engine used to ship three of these — sessions, passkeys, connections —
# and they were where SparrowAuth::RequiresLiveSession was exercised. The pages
# are the buyer's now, written by `rails generate sparrowkit:screens`, and every
# one of them opens by including this concern. The concern itself stayed in the
# engine, so this is the host controller that exercises it: one page, doing
# nothing, behind the guard.
#
# It renders the two things the concern exposes, because those are what a
# generated page reads: who is signed in, and which of their session rows is
# this browser.
class AccountSettingsController < ActionController::Base
  include SparrowAuth::RequiresLiveSession

  def show
    render plain: [current_account.email, current_session_id].join(" ")
  end
end
