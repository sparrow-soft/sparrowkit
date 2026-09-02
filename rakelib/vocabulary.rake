# frozen_string_literal: true

# Words this repository has decided against, held to across everything.
#
# The list is short and every entry earned its place by being wrong in a way a
# reader could not see. "Rung" was ours: it meant a position on a ladder, and
# ADR 0025 removed the ladder — `at_least?` is set containment, so nothing has
# a position any more. The word outlived the idea by three months and went on
# teaching it, in the resolver, in both generators, and in the prompt the
# console writes for an assistant to read.
#
# It was cleaned out of the console guide once, in isolation, and 137 uses
# survived elsewhere and drifted back into conversation and into new work. That
# is the failure this task exists to prevent: a vocabulary fixed in one file is
# a vocabulary that comes back.
#
# In the gate rather than in a gem's suite because the word does not respect
# gem boundaries — it was in sparrow_auth, in sparrow_pay's specs, in the
# decision records, and in AGENTS.md.
# Module rather than constants in the namespace block: a constant defined inside
# `namespace do ... end` is defined on Object, which standardrb refuses for the
# good reason that it is invisible from where it appears to live.
module RetiredWords
  RETIRED = {
    "rung" => "Say `role` for what somebody is in an organization and " \
              "`sign-in method` for passkeys, emailed codes, links, social and " \
              "passwords.",

    # Added late, and that is the point of the entry.
    #
    # This gate was built to catch exactly this: a word renamed in one place and
    # left behind in others. Both of these were renamed during the 0.1.0 reset
    # and neither was ever added here, so the gate went on reporting "no retired
    # words" across five hundred files while the rename it existed for went
    # unchecked. A gate that bans one word is a gate that passes.
    "capability" => "Say `permission` for a `resource:action` name, and `role` " \
                    "for the named set of permissions somebody holds.",

    # The second mail stream. The panel called it this while the README,
    # Postmark and the conformance suite called it `broadcast`, and the
    # library refused the README's header as an unknown stream on every
    # application the panel had configured. One word now, everywhere.
    "marketing" => "Say `broadcast` for the second mail stream: bulk mail, " \
      "newsletters, anything sent to a list. See SparrowMail::CREDENTIALS_STREAM_ALIASES.",

    "role_ladder" => "There is no ladder. A role is a set of permissions, and " \
                     "one role reaches another when it holds everything that " \
                     "one holds -- see SparrowAuth::Role#includes?.",

    # The two the 0.1.0 reset deleted outright. A file that names either is
    # describing a product the buyer does not receive.
    #
    # Added in Phase 8 rather than Phase 7, because adding them in Phase 7 fired
    # 48 times in files that ship -- the README taught the resolver pattern,
    # template/AGENTS.md told an assistant to write one, the install generator
    # wrote an initializer describing it. That was the documentation rewrite
    # rather than a defect sweep, and pulling it forward would have been quietly
    # widening a phase. This is the rewrite, so this is where they go.
    # Qualified, and the qualifier is the whole entry.
    #
    # Bare `resolver` fired on `ActionView::Resolver`, on this repository's own
    # style rule quoting the word as an example of one we made up, and on three
    # DNS resolvers in a smoke script -- where it is simply the correct term for
    # a different thing. That is the third time a single common noun has been
    # tried here and the third time it has cried wolf. `grant` was the first.
    #
    # The retired things had names: the permission resolver and the billing
    # resolver. Neither phrase means anything else.
    "permission resolver" => "Gone in 0.1.0. There is one authorization " \
                             "question and it is asked of a membership in an " \
                             "organization.",

    "billing resolver" => "Gone in 0.1.0. Billing is " \
                          "require_organization!(permission: \"billing:manage\") " \
                          "like everything else.",

    "resource role" => "Gone in 0.1.0. A role is what somebody is in an " \
                       "organization. There is no per-record role."

    # `grant` was in this list for about an hour and is deliberately not now.
    #
    # It fired 132 times and every one was correct English: a licence grants
    # rights, OAuth calls its exchange a grant, and the delivery worker mints a
    # download grant. The retired thing was `Grant` the model, which no longer
    # exists and cannot be typed by accident. A word belongs here only when its
    # ordinary meaning is not also in use -- a gate that cries wolf is a gate
    # somebody turns off.
  }.freeze

  # WHAT THIS GATE GOVERNS: everything that is code, and everything that ships.
  # Not the record of what this repository used to think.
  #
  # `docs/` never reaches a buyer -- it is export-ignored, and `docs:check`
  # holds the shipping line from the other side -- and what is in it is a
  # history: decision records that argued for the capability resolver, briefs
  # that planned its removal, a changelog of releases that had it. Those
  # documents have to be able to name the thing they are about. Rewriting them
  # to use today's words would not improve anybody's vocabulary; it would delete
  # the reason the word was retired.
  #
  # This is a scope, decided once and written down, and not the thing this file
  # warned about: exempting a document to make a case go away, one at a time,
  # until the list is the codebase. Everything that a buyer can read, and every
  # line of Ruby, ERB, rake and template in the repository, is still checked.
  #
  # Everything else tracked, minus the files whose SUBJECT is the vocabulary and
  # which therefore have to be able to name it.
  SKIPPED_TREES = ["docs/", "CHANGELOG.md"].freeze
  # Words matched in lower case only.
  #
  # The two retired phrases are prose and not Ruby constants, so a sentence
  # about Rails' own ActionView::Resolver is not a use of either.
  LOWER_CASE_ONLY = ["permission resolver", "billing resolver"].freeze

  ALLOWED = [
    "gems/sparrow_auth/spec/console/guide_api_spec.rb",
    # The old stream key has to be named by the code that still reads it and
    # by the specs that prove it is read.
    "gems/sparrow_mail/lib/sparrow_mail.rb",
    "gems/sparrow_mail/spec/sparrow_mail/credentials_spec.rb",
    "gems/sparrow_mail/spec/requests/console/sparrowkit_spec.rb",
    "rakelib/vocabulary.rake",
    "plan.md"
  ].freeze
end

namespace :vocabulary do
  desc "Refuse words this repository has retired"
  task :check do
    retired = RetiredWords::RETIRED
    allowed = RetiredWords::ALLOWED

    tracked = `git ls-files -z`.split("\x0").reject(&:empty?)
    offences = []

    tracked.each do |path|
      next if allowed.include?(path)
      next if RetiredWords::SKIPPED_TREES.any? { |tree| path.start_with?(tree) }
      next unless File.file?(path)
      next if path.start_with?("gems/sparrow_ui/node_modules/")

      body = File.read(path, encoding: "UTF-8")
      next unless body.valid_encoding?

      body.each_line.with_index(1) do |line, number|
        retired.each_key do |word|
          pattern = if RetiredWords::LOWER_CASE_ONLY.include?(word)
            /\b#{word}s?\b/
          else
            /\b#{word}s?\b/i
          end
          next unless line.match?(pattern)

          offences << [path, number, word, line.strip]
        end
      end
    rescue ArgumentError
      next # a binary file git tracked; nothing to read
    end

    if offences.any?
      offences.each do |path, number, word, line|
        warn "#{path}:#{number} uses #{word.inspect} — #{retired[word]}"
        warn "  #{line}"
      end
      abort "#{offences.length} use(s) of a retired word."
    end

    puts "Vocabulary checked: #{tracked.length} tracked files, no retired words."
  end
end
