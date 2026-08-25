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

  # The install instructions, against what Bundler can actually resolve.
  #
  # SparrowKit is not on RubyGems, and the gems pin each other to an exact
  # version, so a bare `gem "sparrow_auth"` cannot resolve: Bundler goes looking
  # for `sparrow_mail = 1.0.1` on rubygems.org and does not find it. Every
  # README showed that bare form, which meant the first thing anybody tried
  # after landing on the repository failed.
  #
  # Whenever these gems are published, this check is the thing to delete.
  describe "the install instructions" do
    def documents_declaring_a_gem
      shipped_documents.select { |path|
        path.end_with?(".md") && read_utf8(path).match?(/^\s*gem "sparrow_/)
      }
    end

    it "never shows a bare gem line while the gems are unpublished" do
      expect(documents_declaring_a_gem).not_to be_empty,
        "no install snippets found — has the scan broken?"

      bare = documents_declaring_a_gem.reject { |path| read_utf8(path).include?(GIT_SOURCE) }
        .map { |path| path.delete_prefix("#{ROOT}/") }

      expect(bare).to be_empty,
        "#{bare.join(", ")} declares a sparrow gem without the git source. " \
        "That Gemfile cannot resolve: the gems are not on RubyGems and pin " \
        "each other exactly."
    end

    it "pins the tag to the version being released" do
      version = read_utf8(File.join(ROOT, "VERSION")).strip

      wrong = documents_declaring_a_gem.filter_map { |path|
        tag = read_utf8(path)[/tag: "v([0-9.]+)"/, 1]
        next if tag.nil? || tag == version

        "#{path.delete_prefix("#{ROOT}/")} pins v#{tag}"
      }

      expect(wrong).to be_empty,
        "#{wrong.join(", ")}, but VERSION says #{version}. " \
        "The install snippets pin a release; bump them with the version."
    end
  end

  # The versions a README promises, against the versions the gemspecs require.
  #
  # These drifted silently: the gemspecs moved to Ruby 3.2 and Rails 8.1 while
  # both READMEs still said 3.1 and 7.1, so a developer checking whether they
  # could use SparrowKit got the wrong answer from the only file they would
  # think to read.
  describe "the versions a README promises" do
    def gemspec_for(gem)
      read_utf8(File.join(ROOT, "gems", gem, "#{gem}.gemspec"))
    end

    GEMS.each do |gem|
      readme_path = File.join("gems", gem, "README.md")

      it "#{readme_path} agrees with the gemspec about Ruby" do
        readme = read_utf8(File.join(ROOT, readme_path))
        claimed = readme[/Needs Ruby (\d+\.\d+)/, 1]
        next if claimed.nil?

        required = gemspec_for(gem)[/required_ruby_version = ">= (\d+\.\d+)"/, 1]

        expect(claimed).to eq(required),
          "#{readme_path} says Ruby #{claimed}, the gemspec requires #{required}."
      end

      it "#{readme_path} agrees with the gemspec about Rails" do
        readme = read_utf8(File.join(ROOT, readme_path))
        claimed = readme[/Rails (\d+\.\d+) or\s*\n?newer/, 1] || readme[/Rails (\d+\.\d+) or newer/, 1]
        next if claimed.nil?

        spec = gemspec_for(gem)
        required = spec[/add_dependency "(?:rails|railties)", ">= (\d+\.\d+)"/, 1]
        next if required.nil?

        expect(claimed).to eq(required),
          "#{readme_path} says Rails #{claimed}, the gemspec requires #{required}."
      end
    end
  end

  # What actually went wrong before: a README kept teaching an API after the
  # code went. These names are removed for good, so any shipped document naming
  # one is out of date by definition.
  describe "every shipped document" do
    REMOVED_APIS.each do |api, why|
      it "does not teach #{api}" do
        offenders = shipped_documents.select { |path|
          # Two files name these on purpose and must be allowed to. AGENTS.md
          # has the table saying they are gone, and a CHANGELOG cannot record
          # that something was removed without naming the thing removed.
          next false if %w[AGENTS.md CHANGELOG.md].include?(File.basename(path))

          read_utf8(path).include?(api)
        }.map { |path| path.delete_prefix("#{ROOT}/") }

        expect(offenders).to be_empty,
          "#{offenders.join(", ")} still teaches `#{api}` -- #{why}."
      end
    end
  end
end
