# frozen_string_literal: true

require "rails_helper"

# The first account and the first organization.
#
# What is worth testing here is not that two rows appear. It is the three
# things somebody would otherwise get wrong by hand and only find out about
# later: the account has to be VERIFIED or no sign-in code is ever sent to it,
# the organization has to be created through create_with_owner! because there is
# nobody to name as the assigner, and running the task twice must not produce a
# second of anything.
RSpec.describe SparrowAuth::Seed do
  describe ".run" do
    it "creates one verified account at the reserved address" do
      described_class.run

      account = SparrowAuth::Account.find_by_email(described_class::EMAIL)
      expect(account).to be_present
      expect(account).to be_verified
    end

    # Not decoration. SparrowAuth::SignIn refuses to send a code to an
    # unverified address, so a seeded account that was not verified could not
    # sign in -- which is the single thing it exists to do.
    it "makes an account that can actually be sent a sign-in code" do
      described_class.run

      expect {
        SparrowAuth::SignIn.request(email: described_class::EMAIL, ip: "127.0.0.1")
      }.to change { SparrowMail.deliveries.size }.by(1)

      expect(SparrowMail.deliveries.last.text_body).to match(/\b\d{6}\b/)
    end

    it "makes the account an owner of an organization" do
      result = described_class.run

      membership = result[:account].memberships.sole
      expect(membership.organization).to eq(result[:organization])
      expect(membership.role.to_sym).to eq(:owner)
    end

    it "names the organization after the application" do
      expect(described_class.run[:organization].name).to eq("Dummy")
    end

    describe "running it again" do
      it "creates nothing a second time" do
        described_class.run

        counts = -> {
          [SparrowAuth::Account.count, SparrowAuth::Organization.count, SparrowAuth::Membership.count]
        }

        expect { described_class.run }.not_to change(&counts)
      end

      it "says it changed nothing, rather than saying it created something" do
        described_class.run

        lines = []
        described_class.run(reporter: ->(line) { lines << line })

        expect(lines.first).to match(/already here/i)
      end
    end

    # An application that already has people does not want a fake organization
    # beside their real ones, and it certainly does not want this account
    # promoted into one of theirs.
    it "leaves an account it did not create alone" do
      theirs = SparrowAuth::Account.create!(
        email: "real@example.org", status_id: SparrowAuth::Account::VERIFIED
      )
      org = SparrowAuth::Organization.create_with_owner!(account: theirs, name: "Theirs")

      described_class.run

      expect(theirs.reload.organizations).to eq([org])
      expect(org.memberships.count).to eq(1)
    end

    describe "the environment" do
      it "refuses anything but development and test" do
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("staging"))

        expect { described_class.run }
          .to raise_error(described_class::RefusedEnvironment, /staging/)
      end

      # Named as an allowlist rather than as "not production", because a
      # denylist naming one environment says nothing about the others -- and
      # staging is the one that would have been seeded.
      it "refuses production by the same rule, not a separate one" do
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))

        expect { described_class.run }.to raise_error(described_class::RefusedEnvironment)
      end

      it "creates nothing when it refuses" do
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))

        expect { described_class.run }.to raise_error(described_class::RefusedEnvironment)
        expect(SparrowAuth::Account.count).to eq(0)
      end
    end
  end

  describe ".during_install" do
    it "seeds and names the account in the install summary" do
      lines = described_class.during_install

      expect(lines.first).to include(described_class::EMAIL)
      expect(lines.join(" ")).to include("/sign-in")
      expect(SparrowAuth::Account.count).to eq(1)
    end

    it "says nothing, and creates nothing, in an application that has people" do
      SparrowAuth::Account.create!(
        email: "real@example.org", status_id: SparrowAuth::Account::VERIFIED
      )

      expect(described_class.during_install).to eq([])
      expect(SparrowAuth::Account.count).to eq(1)
    end

    # Everything sparrow_auth actually needs is written by the time this runs,
    # so a seed that could not be created is a thing to say and carry on from --
    # not a reason to abort a finished install and leave somebody working out
    # which half of it happened.
    it "reports a failure as a line to read, not as an exception" do
      allow(described_class).to receive(:run).and_raise(ActiveRecord::StatementInvalid, "no such table")

      expect { @lines = described_class.during_install }.not_to raise_error
      expect(@lines.first).to include("sparrow_auth:seed")
    end
  end

  describe ".wanted?" do
    it "is true for an application with nobody in it" do
      expect(described_class).to be_wanted
    end

    # What the installer asks. An application with its own people has no use for
    # a seeded organization sitting beside their real ones.
    it "is false once any account exists, seeded or not" do
      SparrowAuth::Account.create!(
        email: "real@example.org", status_id: SparrowAuth::Account::VERIFIED
      )

      expect(described_class).not_to be_wanted
    end

    it "is false in an environment it would refuse to run in" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))

      expect(described_class).not_to be_wanted
    end
  end
end
