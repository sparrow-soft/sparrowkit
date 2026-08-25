# frozen_string_literal: true

require "rails_helper"
require "rails/generators"
require "generators/sparrow_auth/install/install_generator"

# The initializer a host actually reads.
#
# The failure worth guarding against is drift: a setting gets added to
# Configuration and nobody mentions it in the file people are told to configure
# from. That is not hypothetical — the README's settings table had fallen six
# behind before this generator existed, and every one of the six was from the
# three most recent phases.
#
# So the first test below compares the template against the real configuration
# object rather than against a list somebody maintains by hand.
RSpec.describe "sparrow_auth:install" do
  let(:destination) { Rails.root.join("tmp/install-spec") }

  before do
    FileUtils.rm_rf(destination)
    FileUtils.mkdir_p(destination.join("config"))
    File.write(destination.join("config/routes.rb"), "Rails.application.routes.draw do\nend\n")
  end

  after { FileUtils.rm_rf(destination) }

  def run(args = [])
    SparrowAuth::Generators::InstallGenerator.start(
      args, destination_root: destination, shell: Thor::Shell::Basic.new
    )
  end

  def initializer
    File.read(destination.join("config/initializers/sparrow_auth.rb"))
  end

  def settings
    SparrowAuth::Configuration.instance_methods(false)
      .map(&:to_s)
      .select { |name| name.end_with?("=") }
      .map { |name| name.delete_suffix("=") }
  end

  # The whole point of generating this rather than documenting it: a file that
  # ships beside the code cannot fall behind it silently.
  #
  # A setting counts as mentioned if it appears EITHER as a `config.` line or
  # in the closing list of what the control panel owns. That second form is not
  # a loophole -- it is the point. Seven settings used to be shown here as
  # commented assignments AND be editable in the panel, and because this file
  # is evaluated after credentials are read, uncommenting one silently beat
  # whatever the developer had just saved. They were removed as assignments and
  # kept as documentation, which is what this allows for.
  it "mentions every setting the configuration object has" do
    run

    missing = settings.reject { |setting|
      initializer.include?("config.#{setting}") || initializer.match?(/^\s*#\s+#{setting}\s{2,}\S/)
    }

    expect(missing).to be_empty,
      "The initializer does not mention: #{missing.join(", ")}.\n" \
      "A setting nobody is told about is a setting nobody sets deliberately."
  end

  # The other half, and the reason the rule above is not just "mention it
  # somewhere": a setting the panel writes must NOT also be assignable here.
  it "assigns nothing the control panel writes" do
    run

    # What SparrowAuth::Console::SparrowkitController stores, named here rather
    # than reached for: this spec has to describe the same list even in a host
    # that has no console gem installed at all.
    panel_owned = %w[
      webauthn_rp_id webauthn_rp_name mail_from
      signup_with_code passwords_enabled otp_secret api_token_secret
    ]

    conflicting = panel_owned.select { |setting| initializer.include?("config.#{setting}") }

    expect(conflicting).to be_empty, <<~MSG
      The initializer offers assignments for settings the control panel also writes:

        #{conflicting.join(", ")}

      config/initializers is evaluated AFTER the engine reads credentials, so a
      line here wins over the panel silently. One value must have one place to
      be set, and for these that place is http://localhost:3000/sparrowkit/auth.
      Document them in the closing list instead.
    MSG
  end

  it "writes Ruby that parses" do
    run

    expect { RubyVM::AbstractSyntaxTree.parse(initializer) }.not_to raise_error
  end

  # Every mention has to be commented out except the ones a host must own,
  # or generating the file would silently change behaviour.
  it "leaves everything at its default except the mount point" do
    run

    live = initializer.lines
      .map(&:strip)
      .select { |line| line.start_with?("config.") }

    expect(live).to eq(['config.path_prefix = "/auth"'])
  end

  it "keeps path_prefix agreeing with the mount point" do
    run(["--mount-at=/accounts"])

    expect(initializer).to include('config.path_prefix = "/accounts"')
    expect(File.read(destination.join("config/routes.rb")))
      .to include('mount SparrowAuth::Engine => "/accounts"')
  end

  it "mounts the engine" do
    run

    expect(File.read(destination.join("config/routes.rb")))
      .to include('mount SparrowAuth::Engine => "/auth"')
  end

  # The decision that matters, and the reason it matters, have to survive
  # somebody skimming.
  #
  # It is no longer set in this file -- the panel owns it -- but the warning
  # still belongs at the top rather than in the closing list. It is the one
  # setting here that cannot be corrected later by changing a setting, and a
  # developer who reads nothing else should still meet it.
  it "puts the decision that matters first, and says why" do
    run

    head = initializer.lines.first(40).join

    expect(head).to include("webauthn_rp_id")
    expect(head).to include("enrolling again")
    expect(head).to include("/sparrowkit/auth")
  end

  # Matched against the prose with its wrapping removed. The comment is
  # hard-wrapped, so a substring search finds half a sentence and reports a
  # missing paragraph that is plainly there.
  it "says which rule has no setting" do
    run

    prose = initializer.gsub(/^\s*#\s?/, "").gsub(/\s+/, " ")

    expect(prose).to include("not trusted until it has been verified")
    expect(prose).to include("There is no setting for that")
  end

  # An existing initializer is the developer's, full stop. Thor's default on a
  # collision is to PROMPT, and a prompt read from a closed stdin -- an agent,
  # CI, anything piped -- answers itself YES. That replaced a host application's
  # customized initializer (its after_first_signin hook, its mail_from) with the
  # stock copy, silently, on an ordinary re-run of the app template.
  describe "when the initializer already exists" do
    it "never overwrites it, byte for byte" do
      run
      customized = initializer.sub(
        'config.path_prefix = "/auth"',
        "config.path_prefix = \"/auth\"\n  config.after_first_signin = ->(account) { account.build_tenant! }"
      )
      File.write(destination.join("config/initializers/sparrow_auth.rb"), customized)

      run

      expect(initializer).to eq(customized)
    end

    it "says the file is already the developer's, and where the stock copy is" do
      run

      expect { run }.to output(
        %r{already yours.*#{Regexp.escape("sparrow_auth.rb.tt")}}m
      ).to_stdout
    end
  end
end
