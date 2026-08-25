# frozen_string_literal: true

require "tmpdir"

# The one adapter that runs no conformance driver, and the reason is worth
# stating rather than leaving as an absence.
#
# The conformance suite proves that every PROVIDER adapter behaves identically
# against a network: the same errors from the same status codes, one request per
# send, no body in a log line. Its driver contract is built around injecting
# provider failures — authentication, rate limit, server error — and this
# adapter has no provider and cannot produce any of them. Writing a driver would
# mean adding failure injection to a production adapter for the suite's benefit,
# which is a worse trade than this file.
#
# So what is proven here instead is everything that could actually go wrong: it
# writes something a mail client can open, it reads back what it wrote, a
# filename cannot be chosen by a recipient, clearing deletes messages and
# nothing else, and an unwritable folder says which folder.
RSpec.describe SparrowMail::Adapters::Preview do
  # A real folder, pointed at explicitly, rather than a stubbed method.
  #
  # This ran from inside a temporary working directory instead, on the reasoning
  # that this gem's suite has no Rails and the adapter would therefore resolve
  # against Dir.pwd. That reasoning was wrong the moment the whole suite ran
  # together: the console request specs boot a Rails application, so `Rails` is
  # defined for the rest of the process, every example wrote to the same
  # Rails.root/tmp folder, and they counted each other's mail.
  around do |example|
    Dir.mktmpdir("preview-spec") do |dir|
      described_class.directory = File.join(dir, "mail")
      begin
        example.run
      ensure
        described_class.directory = nil
      end
    end
  end

  let(:adapter) { described_class.new }

  describe "writing" do
    it "writes one file per message" do
      adapter.deliver!(build_mail(subject: "First"))
      adapter.deliver!(build_mail(subject: "Second"))

      expect(described_class.count).to eq(2)
    end

    it "makes the folder if it is not there" do
      expect { adapter.deliver!(build_mail) }
        .to change { Dir.exist?(described_class.directory) }.from(false).to(true)
    end

    it "writes something a mail client can open" do
      adapter.deliver!(build_mail(to: "person@example.org", subject: "Readable"))

      reread = Mail.read(described_class.files.first)
      expect(reread.to).to eq(["person@example.org"])
      expect(reread.subject).to eq("Readable")
    end

    it "reports a message id, so a caller cannot tell it apart from a send" do
      expect(adapter.deliver!(build_mail).message_id).to start_with("preview-")
    end

    # The filename is built from the clock and random bytes, never from the
    # message. A recipient is attacker-supplied text, and a path built from
    # attacker-supplied text is a path an attacker chooses.
    it "puts nothing from the message in the filename" do
      adapter.deliver!(build_mail(to: "../../etc/passwd@example.org", subject: "Nice try"))

      name = File.basename(described_class.files.first)
      expect(name).to match(/\A\d{8}T\d{12}-[0-9a-f]{6}\.eml\z/)
    end

    # The random suffix exists for this and for nothing else: two processes --
    # a server and a job runner -- writing in the same instant must not land on
    # one filename and lose a message. Ordering is the timestamp's job, which is
    # why it is measured in microseconds.
    it "keeps every message when two are written at the same instant" do
      allow(Time).to receive(:now).and_return(Time.at(1_700_000_000))

      3.times { adapter.deliver!(build_mail) }

      expect(described_class.count).to eq(3)
    end

    # An envelope handed straight to SparrowMail.deliver! carries no Mail
    # object, so the file has to be composed. Through Mail rather than by
    # joining strings: a subject holding a newline must not be able to write a
    # header of its own.
    it "composes a file for an envelope that carries no message" do
      envelope = SparrowMail::Envelope.new(
        from: SparrowMail::Address.new("from@example.org"),
        to: [SparrowMail::Address.new("to@example.org")],
        subject: "Plain",
        text_body: "Body text"
      )

      adapter.deliver_envelope(envelope)

      reread = Mail.read(described_class.files.first)
      expect(reread.subject).to eq("Plain")
      expect(reread.body.decoded).to include("Body text")
    end
  end

  describe "reading back" do
    # Ordered every time, not most of the time. This read ["Older", "Newer"]
    # under about one seed in three: both files landed in the same millisecond,
    # tied on the timestamp, and were then sorted by the random suffix.
    it "returns the newest first" do
      10.times do |n|
        adapter.deliver!(build_mail(subject: "Message #{n}"))
      end

      expect(described_class.recent.map(&:subject))
        .to eq(9.downto(0).map { |n| "Message #{n}" })
    end

    it "takes the text body out of a multipart message" do
      adapter.deliver!(build_mail(text: "Hello there", html: "<p>Hello there</p>"))

      expect(described_class.recent.first.text).to include("Hello there")
    end

    it "honours the limit" do
      3.times { |n| adapter.deliver!(build_mail(subject: "Message #{n}")) }

      expect(described_class.recent(limit: 2).size).to eq(2)
    end

    # `mail` parses rather than validates: handed a run of binary it returns a
    # Message with no recipient, no subject and no body instead of raising. So a
    # rescue alone would have put a blank row on the panel and called it
    # working, which is how this test found its own first version.
    it "skips a file that is not a message, rather than showing a blank row" do
      adapter.deliver!(build_mail(subject: "Fine"))
      File.write(File.join(described_class.directory, "99999999T999999999-abcdef.eml"), "\x00 not mail")

      expect(described_class.recent.map(&:subject)).to eq(["Fine"])
    end

    it "reads an empty folder as no messages" do
      expect(described_class.recent).to eq([])
      expect(described_class.count).to eq(0)
    end
  end

  describe "clearing" do
    it "deletes the messages" do
      2.times { adapter.deliver!(build_mail) }

      expect { described_class.clear! }.to change(described_class, :count).from(2).to(0)
    end

    # Unlinks the files it knows about rather than removing the folder, because
    # the folder is a path derived from Rails.root and `rm_rf` on one of those
    # is how a tidy-up button becomes an incident.
    it "leaves the folder, and anything in it that is not a message" do
      adapter.deliver!(build_mail)
      keep = File.join(described_class.directory, "notes.txt")
      File.write(keep, "mine")

      described_class.clear!

      expect(Dir.exist?(described_class.directory)).to be(true)
      expect(File.exist?(keep)).to be(true)
    end
  end

  describe "when the folder cannot be written to" do
    it "says which folder, as a configuration problem" do
      allow(FileUtils).to receive(:mkdir_p).and_raise(Errno::EACCES)

      expect { adapter.deliver!(build_mail) }
        .to raise_error(SparrowMail::ConfigurationError, /#{Regexp.escape(described_class.directory)}/)
    end
  end

  describe "where it writes" do
    it "takes a folder it is given" do
      Dir.mktmpdir("elsewhere") do |dir|
        described_class.directory = dir
        adapter.deliver!(build_mail)

        expect(described_class.files.first).to start_with(File.expand_path(dir))
      end
    end

    it "goes back to the default when that is cleared" do
      described_class.directory = nil

      expect(described_class.directory).to end_with(described_class::DIRECTORY)
    end
  end

  describe "what it says about itself" do
    it "is not a provider, so the control panel does not offer it" do
      expect(described_class).not_to be_provider
    end

    it "bears no reputation, having no provider to have one with" do
      expect(described_class).not_to be_reputation_bearing
    end

    it "needs no settings" do
      expect(described_class.required_settings).to be_empty
    end
  end
end
