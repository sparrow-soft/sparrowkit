# frozen_string_literal: true

require "rails_helper"

# How the console asks for a secret.
#
# The rule this pins is one line long and easy to undo by accident: a box you
# paste an API key into must NOT be `type="password"`.
#
# That attribute is what makes a browser offer to save the value to the user's
# password manager and offer to fill it back in later. An API key is not a
# credential for this site -- it belongs to Postmark or Stripe and is merely
# being typed here -- so the offer files it under the wrong name, in a vault it
# will later be autofilled from into the wrong box.
#
# `autocomplete="off"` cannot turn that off. Every major browser deliberately
# ignores it on password fields, because sites once used it to stop people
# using a password manager at all. So the field is a text box masked in CSS,
# and this spec is the thing standing between that decision and somebody
# "fixing" it back to type="password" because it looks like a password.
RSpec.describe "the console's secret fields", type: :request do
  before { allow(Rails.env).to receive(:development?).and_return(true) }

  def get_panel(path)
    get path, env: {"REMOTE_ADDR" => "127.0.0.1"}
  end

  # sparrow_mail is the panel this dummy boots with, and its API key fields are
  # the real thing rather than a fixture -- rendered through the same partial
  # every panel uses.
  let(:body) { get_panel("/sparrowkit/mail") && response.body }

  # The first secret input, whole. Extracted rather than matched in place:
  # asserting `data-1p-ignore[^>]*name=` quietly encodes the order attributes
  # happen to be written in, and then fails on a reordering that changes
  # nothing. Pull the tag out, then ask what is in it.
  def secret_input
    body[/<input[^>]*data-1p-ignore[^>]*>/m]
  end

  it "renders no password input anywhere on a panel" do
    expect(body).not_to include(%(type="password"))
  end

  it "masks the value in CSS instead, so it still reads as a secret" do
    expect(body).to include("[-webkit-text-security:disc]")
  end

  # Belt and braces for the managers that scan fields themselves rather than
  # trusting the browser. Each is that vendor's documented opt-out.
  it "opts out of every password manager that offers a way to" do
    expect(secret_input).to be_present
    expect(secret_input).to include(%(data-lpignore="true"))
    expect(secret_input).to include("data-bwignore")
    expect(secret_input).to include(%(data-form-type="other"))
  end

  it "asks the browser not to autofill, at the field and at the form" do
    expect(secret_input).to include(%(autocomplete="off"))
    expect(body).to match(/<form[^>]*autocomplete="off"/m)
  end

  # The masking is a look, not a security boundary, and the value still has to
  # arrive under the name the controller reads. A field that masked correctly
  # and posted nothing would look completely fine.
  # Matched on the SHAPE rather than on "primary[settings][postmark][api_key]".
  # Which card and which adapter come first is sparrow_mail's business and it
  # may reasonably add or reorder them; that the nesting arrives intact is
  # sparrow_ui's.
  it "keeps the name the panel saves under" do
    expect(secret_input).to match(/name="\w+\[settings\]\[\w+\]\[\w+\]"/)
  end

  # Rendered blank on every load, whatever is stored. A secret written back
  # into the page is a secret in the HTML, in the browser's cache and in any
  # screenshot of the console -- and the panel shows the last four characters
  # beside the label instead, which is enough to tell which key is in there.
  it "never writes a stored secret back into the page" do
    expect(secret_input).to include(%(value=""))
  end
end
