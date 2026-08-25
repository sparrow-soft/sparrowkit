# frozen_string_literal: true

require "rails_helper"

# Every method the guide names has to exist.
#
# The guide is rendered on the console's front page and folded into a prompt
# written to be pasted into an assistant, so a method named here that does not
# exist is worse than a missing doc: it is a confident instruction to call
# nothing, and an assistant will write code around it without hesitating.
#
# Three had already got in -- `sparrow_auth_signed_in?`, `current_account.can?`
# and `require_authentication!` -- none of which ever existed anywhere in this
# gem. They were caught by hand, which is not a method that scales.
RSpec.describe "the API sparrow_auth's guide names" do
  let(:guide) { SparrowAuth::Console::Guide.new }

  let(:text) { [guide.steps.join("\n"), guide.brief].join("\n") }

  # Read off the modules rather than listed here, so renaming one there fails
  # this. Both modules, because require_organization! moved out of Tenancy into
  # Authorization -- and a spec reading only Tenancy would have called the
  # method that survived the move a method that does not exist.
  def concern_methods
    [SparrowAuth::Tenancy].flat_map { |concern|
      concern.private_instance_methods(false) + concern.instance_methods(false)
    }.map(&:to_s)
  end

  it "names only helpers the controller concerns actually define" do
    named = text.scan(/\bcurrent_[a-z_]+\b/).uniq

    missing = named.reject { |method| concern_methods.include?(method) }

    expect(missing).to be_empty,
      "the guide names #{missing.join(", ")}, which no controller concern defines"
  end

  it "names only guard methods that exist" do
    named = (text.scan(/\brequire_[a-z_]+!?/) + text.scan(/\bskip_[a-z_]+!?/) +
      text.scan(/\bmay\?/)).uniq

    missing = named.reject { |method| concern_methods.include?(method) }

    expect(missing).to be_empty,
      "the guide names #{missing.join(", ")}, which does not exist"
  end

  # The resolver, grants and the policy generator are gone. The guide is
  # written to be pasted into an assistant, which will believe it and write
  # code around a class that is not there.
  it "does not teach the subsystem that was deleted" do
    %w[authorize! reachable_by SparrowAuth::Resolver SparrowAuth::Grant Access.resolve].each do |ghost|
      expect(text).not_to include(ghost),
        "#{ghost} no longer exists; the guide is written to be believed"
    end
  end

  # The two that were invented, named explicitly. A regex over the source could
  # drift; these cannot come back without this failing.
  it "does not resurrect the methods that were never real" do
    %w[sparrow_auth_signed_in? require_authentication! current_account.can?].each do |ghost|
      expect(text).not_to include(ghost),
        "#{ghost} does not exist and never did"
    end
  end

  # The guide named the roles as "member < admin < owner, ordered". Every part
  # of that was wrong once ADR 0025 landed: five roles ship rather than three,
  # one counts as at least another by holding everything it holds rather than by
  # sitting above it, and an application may declare its own. It is worse than a
  # stale sentence because this text is written to be pasted into an assistant,
  # which will believe it and write a rank comparison.
  it "does not describe roles as a ladder" do
    %w[rung rungs].each do |word|
      expect(text.downcase).not_to match(/\b#{word}\b/),
        "the guide says #{word.inspect}; roles are named sets of permissions, not positions"
    end

    expect(text).not_to match(/member\s*<\s*admin/),
      "the guide ranks roles against each other; at_least? is set containment"
  end

  # The prompt reports the configuration as fact. Reading only this gem's own
  # key calls the passkey domain "not set" for an application that answered it
  # on the console's front page — and an assistant handed that will write code
  # to work around a problem the application does not have.
  it "reports the passkey domain it inherited, not just an override" do
    allow(SparrowAuth).to receive(:application_host).and_return("example.com")
    allow(::SparrowUi::Console::Settings).to receive(:read).and_return({})

    expect(guide.brief).to include("example.com")
    expect(guide.brief).not_to match(/passkey domain: not set/i)
  end

  it "reports the product name it inherited, not just an override" do
    allow(SparrowAuth).to receive(:application_name).and_return("Zephyr Works")
    allow(::SparrowUi::Console::Settings).to receive(:read).and_return({})

    expect(guide.brief).to include("Zephyr Works")
  end

  it "does not tell somebody to install what the installer already did" do
    # This text is read by a developer whose application is running the console,
    # which is only reachable through an engine the installer mounted.
    %w[install:migrations db:migrate mount\ SparrowAuth::Engine].each do |already_done|
      expect(guide.steps.join("\n")).not_to include(already_done)
    end
  end
end
