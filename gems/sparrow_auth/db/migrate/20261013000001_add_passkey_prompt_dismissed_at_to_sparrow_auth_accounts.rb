# frozen_string_literal: true

# When somebody said "Not now" to adding a passkey.
#
# Applications show a one-time card after a sign-in by emailed code, offering
# a passkey instead of the code next time. Asked once per person rather than
# once per browser, so the answer is kept on the account. See
# SparrowAuth::Account#passkey_prompt_due?.
class AddPasskeyPromptDismissedAtToSparrowAuthAccounts < ActiveRecord::Migration[7.1]
  def change
    add_column :sparrow_auth_accounts, :passkey_prompt_dismissed_at, :datetime
  end
end
