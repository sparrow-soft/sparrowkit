# frozen_string_literal: true

# The repository's own specs, as opposed to any one gem's.
#
# These test invariants that do not belong to a single gem: that the
# documentation describes the code that exists, and only the code that exists.
# They read source as text and never load it, so this file stays deliberately
# bare -- no Rails, no engines, nothing to boot.
RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end

ROOT = File.expand_path("..", __dir__)
GEMS = %w[sparrow_mail sparrow_auth sparrow_pay sparrow_ui].freeze

# Every line of Ruby SparrowKit ships, as one string.
#
# From the gemspecs, for the same reason shipped_documents is: a hardcoded
# lib/app/console list is a list that goes stale the first time a gem grows a
# directory. This one fails in the safe direction -- too narrow means claiming
# something does not exist when it does -- but there is no reason to keep two
# answers to the question of what ships.
def shipped_source
  @shipped_source ||= shipped_files
    .grep(/\.rb\z/)
    .map { |path| read_utf8(path) }
    .join("\n")
end

# Always UTF-8, never the locale's guess. A runner with LANG unset reads these
# files as US-ASCII and every check here dies on the first em dash -- which is
# a spec that fails for a reason having nothing to do with what it tests.
def read_utf8(path)
  File.read(path, encoding: "UTF-8")
end

def defines_constant?(name)
  shipped_source.match?(/(class|module) #{Regexp.escape(name)}\b/)
end

def defines_method?(name)
  bare = name.sub(/[!?]\z/, "")
  shipped_source.match?(/def (self\.)?#{Regexp.escape(name)}(?![\w!?])/) ||
    shipped_source.match?(/scope :#{Regexp.escape(bare)}\b/) ||
    shipped_source.match?(/attr_(accessor|reader|writer)[^\n]*:#{Regexp.escape(bare)}\b/)
end

def defines_setting?(name)
  shipped_source.match?(/attr_(accessor|writer) :#{Regexp.escape(name)}\b/)
end

# Rails, RSpec and Pay. SparrowKit does not define these and should not be asked
# to -- but the list is deliberately short, because every entry is a name the
# documentation check stops verifying.
BORROWED_METHODS = %w[
  create! destroy_all raise_error unscope perform_later mark_undeliverable!
  payment_processor subscribed? subscription charges processor_plan active?
].freeze

RUBY_KEYWORDS = %w[
  lambda if unless case when end do expect it raise puts new each to eq be set
  from_now minutes describe include head render
].freeze

# APIs removed for good. Any shipped document naming one is out of date by
# definition -- which is exactly how sparrow_pay and sparrow_auth drifted.
REMOVED_APIS = {
  "require_organization" => "there is no enforced authorization check",
  "skip_authorization" => "there is nothing to skip",
  "permits?" => "there is no permission API",
  "SparrowAuth::Role" => "roles are plain strings",
  "SparrowAuth::Authorization" => "use SparrowAuth::Tenancy",
  "SparrowAuth::Resolver" => "deleted in 0.1.0",
  "SparrowAuth::Grant" => "deleted in 0.1.0",
  "sparrowkit:screens" => "SparrowKit ships no screens",
  "sparrowkit:resource" => "the generator was removed",
  "organization.billing." => "there is no billing object; ask Pay"
}.freeze

# Everything a developer or an agent reads, taken from the gemspecs themselves.
#
# ASK THE GEMSPEC. Do not list directories here.
#
# This has now been wrong twice, the same way both times. It began as *.{md,tt},
# which missed the .erb the console panels are written in -- so two shipped
# panels told people to call a deleted method for two releases. Widening it to
# lib/app/console then missed config/, where a shipped routes.rb was still
# describing a deleted generator. Each fix widened the net to wherever the last
# fault was found, which is not the same as covering what ships.
#
# `spec.files` is the definition of what ships: it is the list RubyGems packages
# and the list a developer installs. Reading it means a new directory added to a
# gemspec is covered the moment it is added, by nobody's remembering.
#
# It also excludes each gem's spec/ for free, which is what we want: a spec that
# asserts an API is gone has to name it, and would otherwise flag itself.
TEXT_FILE = /\.(rb|erb|tt|md)\z/

# Every text file the four gems package, straight from their gemspecs.
def shipped_files
  @shipped_files ||= GEMS.flat_map do |gem|
    dir = File.join(ROOT, "gems", gem)
    spec = Dir.chdir(dir) { Gem::Specification.load("#{gem}.gemspec") }
    raise "could not load #{gem}.gemspec" if spec.nil?

    spec.files.grep(TEXT_FILE).map { |relative| File.join(dir, relative) }
  end
end

def shipped_documents
  shipped_files + Dir.glob(File.join(ROOT, "*.md"))
end

# The git source every install snippet has to carry while the gems are
# unpublished. See spec/docs_spec.rb.
GIT_SOURCE = 'git "https://github.com/sparrow-soft/sparrowkit.git"'
