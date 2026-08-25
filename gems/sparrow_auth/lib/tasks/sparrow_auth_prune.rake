# frozen_string_literal: true

# bin/rails sparrow_auth:prune
#
# Two of this engine's tables grow forever if nothing deletes from them, and
# both hold personal data while they do.
#
# `sparrow_auth_auth_events` is one row per sign-in attempt of any kind, and the
# row is an email address or an IP address beside a timestamp. Kept, that is a
# log of who tried to sign in to what and from where, for as long as the
# application has existed. Its only purpose is to answer "how many of these in
# the last N minutes", so a row older than the longest N answers nothing.
#
# `sparrow_auth_otp_codes` is an email address beside the digest of a sign-in
# code. Once the code has expired the row cannot be redeemed, so what is left is
# the address and a secret nobody needs.
#
# Run it on whatever schedule the application already has for periodic work --
# daily is generous, hourly is fine. It takes no arguments, deletes only rows
# that are past use, and says what it removed.
namespace :sparrow_auth do
  desc "Delete expired sign-in codes and spent rate-limit counters"
  task prune: :environment do
    # The widest window any budget actually uses, asked of the budgets rather
    # than written down here. A hardcoded hour would quietly start deleting live
    # counters the day somebody added a budget with a longer window, and the
    # only symptom would be a rate limit that stopped holding.
    window = SparrowAuth::RateLimiter::BUDGETS.values.flatten.map(&:window).max
    cutoff = Time.current - window

    events = SparrowAuth::AuthEvent.where(SparrowAuth::AuthEvent.arel_table[:created_at].lt(cutoff)).delete_all
    codes = SparrowAuth::OneTimeCode.where(SparrowAuth::OneTimeCode.arel_table[:expires_at].lt(Time.current)).delete_all

    # Counts, not rows. What was deleted is exactly the personal data this task
    # exists to remove, so printing any of it would defeat the point.
    puts "sparrow_auth:prune — #{events} rate-limit #{(events == 1) ? "counter" : "counters"} " \
      "older than #{window.inspect}, #{codes} expired sign-in #{(codes == 1) ? "code" : "codes"}"
  end
end
