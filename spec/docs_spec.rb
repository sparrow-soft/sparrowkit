# frozen_string_literal: true

# The documentation, checked against the code it describes.
#
# This exists because it has already failed twice. `sparrow_pay`'s README, its
# console guide and one of its specs all taught `organization.billing.active?`
# for two releases after the object behind it was deleted; `sparrow_auth`'s
# README taught `require_organization!`, `permits?` and a `sparrowkit:screens`
# generator that had been removed. Both were found by a person reading, which is
# not a control.
#
# Documentation that names something which does not exist is worse than none: an
# agent reads it and writes code that cannot run, confidently.
RSpec.describe "the documentation" do
  # Only the part of AGENTS.md that promises things exist. The table at the end
  # deliberately names APIs that do not, and is checked separately below.
  def agents_md
    @agents_md ||= begin
      text = read_utf8(File.join(ROOT, "AGENTS.md"))
      text[0...text.index("## What does not exist")]
    end
  end

  describe "AGENTS.md" do
    it "names only constants that exist" do
      named = agents_md.scan(/Sparrow(?:Auth|Mail|Pay|Ui)::[A-Z][A-Za-z]+/).uniq

      expect(named).not_to be_empty, "no constants found — has the scan broken?"

      missing = named.reject { |c| defines_constant?(c.split("::").last) }

      expect(missing).to be_empty,
        "AGENTS.md names constants that do not exist: #{missing.join(", ")}.\n" \
        "An agent reading this writes code that raises NameError."
    end

    it "names only methods that exist" do
      named = (agents_md.scan(/\b([a-z_]+[!?]?)\(/).flatten +
               agents_md.scan(/\.([a-z_]+[!?])(?!\w)/).flatten).uniq

      expect(named).not_to be_empty, "no methods found — has the scan broken?"

      missing = (named - BORROWED_METHODS - RUBY_KEYWORDS).reject { |m| defines_method?(m) }

      expect(missing).to be_empty,
        "AGENTS.md names methods that do not exist: #{missing.join(", ")}.\n" \
        "Either the method was removed and the document was not, or the " \
        "document invented it. Both have happened."
    end

    it "names only settings that exist" do
      named = agents_md.scan(/config\.([a-z_]+)/).flatten.uniq

      expect(named).not_to be_empty, "no settings found — has the scan broken?"

      missing = named.reject { |s| defines_setting?(s) }

      expect(missing).to be_empty,
        "AGENTS.md documents settings that do not exist: #{missing.join(", ")}.\n" \
        "config.role_names survived this way: declared, never read, still documented."
    end

    # The inverse, and the half that is easy to forget. The table tells an agent
    # these APIs are not real; if one is ever restored, the table becomes the
    # lie instead.
    it "does not claim something is gone when it has come back" do
      table = read_utf8(File.join(ROOT, "AGENTS.md"))
        .split("## What does not exist").last

      # The FIRST cell of each row only. The second names the replacement --
      # "use `SparrowAuth::Tenancy`" -- and reading the whole row would take
      # the cure for the disease.
      claimed_gone = table.lines
        .select { |line| line.start_with?("|") }
        .filter_map { |line| line.split("|")[1] }
        .join(" ")
        .scan(/`SparrowAuth::([A-Z][A-Za-z]+)`/).flatten.uniq

      expect(claimed_gone).not_to be_empty, "no removed constants listed — has the table changed?"

      resurrected = claimed_gone.select { |c| defines_constant?(c) }

      expect(resurrected).to be_empty,
        "AGENTS.md says these do not exist, but they do: #{resurrected.join(", ")}.\n" \
        "Move them out of the table and document them properly."
    end
  end

  # What actually went wrong before: a README kept teaching an API after the
  # code went. These names are removed for good, so any shipped document naming
  # one is out of date by definition.
  describe "every shipped document" do
    REMOVED_APIS.each do |api, why|
      it "does not teach #{api}" do
        offenders = shipped_documents.select { |path|
          # AGENTS.md names these on purpose, in the table saying they are gone.
          next false if File.basename(path) == "AGENTS.md"

          read_utf8(path).include?(api)
        }.map { |path| path.delete_prefix("#{ROOT}/") }

        expect(offenders).to be_empty,
          "#{offenders.join(", ")} still teaches `#{api}` -- #{why}."
      end
    end
  end
end
