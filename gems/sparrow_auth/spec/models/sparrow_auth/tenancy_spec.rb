# frozen_string_literal: true

require "rails_helper"

# Row-based tenancy, exercised against Widget — a model that lives in the dummy
# application, not in the engine. That matters: the helpers are only worth what
# they do to somebody else's models.
RSpec.describe SparrowAuth::Tenanted do
  let(:acme) { SparrowAuth::Organization.create!(name: "Acme") }
  let(:globex) { SparrowAuth::Organization.create!(name: "Globex") }

  after { SparrowAuth::Current.reset }

  # Restores on the way out. Leaving the last organization set would mean the
  # "no organization in scope" examples ran with one still in scope, and passed
  # for the wrong reason.
  def within(organization)
    previous = SparrowAuth::Current.organization
    SparrowAuth::Current.organization = organization
    yield
  ensure
    SparrowAuth::Current.organization = previous
  end

  describe "scoping" do
    it "returns only the organization in scope" do
      acme_widget = within(acme) { Widget.create!(name: "Acme's") }
      within(globex) { Widget.create!(name: "Globex's") }

      within(acme) do
        expect(Widget.all.to_a).to eq([acme_widget])
      end
    end

    # The failure this whole design exists to prevent: one tenant reaching
    # another's row by id. Nothing about that request looks wrong.
    it "cannot reach another organization's row by id" do
      other = within(globex) { Widget.create!(name: "Globex's") }

      within(acme) do
        expect { Widget.find(other.id) }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    it "counts only the organization in scope" do
      within(acme) { Widget.create!(name: "one") }
      within(globex) { 2.times { |i| Widget.create!(name: "other #{i}") } }

      within(acme) { expect(Widget.count).to eq(1) }
      within(globex) { expect(Widget.count).to eq(2) }
    end

    it "stamps new records with the organization in scope" do
      widget = within(acme) { Widget.create!(name: "stamped") }

      expect(widget.organization_id).to eq(acme.id)
    end
  end

  describe "with no organization in scope" do
    # Raising is the design. Returning everything instead turns one forgotten
    # scope into a page showing every tenant's data, and that page looks
    # completely normal to whoever built it.
    it "raises rather than returning every tenant's rows" do
      within(globex) { Widget.create!(name: "someone else's") }

      expect { Widget.count }.to raise_error(SparrowAuth::UnscopedQuery)
    end

    it "names the model that was queried" do
      expect { Widget.first }.to raise_error(SparrowAuth::UnscopedQuery, /Widget/)
    end

    it "says how to proceed deliberately" do
      expect { Widget.first }.to raise_error(/across_all_organizations/)
    end
  end

  describe "the escape hatch" do
    it "spans every tenant when a reason is given" do
      within(acme) { Widget.create!(name: "acme") }
      within(globex) { Widget.create!(name: "globex") }

      count = SparrowAuth.across_all_organizations(reason: "nightly rollup") { Widget.count }

      expect(count).to eq(2)
    end

    # A reason that could be omitted would be omitted, and the log line would
    # then say only that somebody crossed tenants, not why.
    it "refuses to run without a stated reason" do
      expect {
        SparrowAuth.across_all_organizations(reason: "  ") { Widget.count }
      }.to raise_error(ArgumentError, /reason/)
    end

    it "writes the reason to the log, so the crossing is reviewable later" do
      logged = []
      allow(Rails.logger).to receive(:warn) { |message| logged << message }

      SparrowAuth.across_all_organizations(reason: "operator console") { Widget.count }

      expect(logged.join).to include("across_all_organizations", "operator console")
    end

    # Leaving tenancy off after the block would be the worst possible outcome:
    # every later query in the request silently spanning tenants.
    it "restores scoping afterwards" do
      SparrowAuth.across_all_organizations(reason: "rollup") { Widget.count }

      expect { Widget.count }.to raise_error(SparrowAuth::UnscopedQuery)
    end

    it "restores scoping even when the block raises" do
      begin
        SparrowAuth.across_all_organizations(reason: "rollup") { raise "boom" }
      rescue RuntimeError
        nil
      end

      expect { Widget.count }.to raise_error(SparrowAuth::UnscopedQuery)
    end

    it "restores the outer state when nested, not the absence of one" do
      within(acme) do
        SparrowAuth.across_all_organizations(reason: "outer") do
          SparrowAuth.across_all_organizations(reason: "inner") { Widget.count }
          expect(Widget.count).to eq(Widget.unscoped.count)
        end

        expect(Widget.count).to eq(0)
      end
    end
  end
end
