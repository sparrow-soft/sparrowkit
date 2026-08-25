# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "mail"
require_relative "base"

module SparrowMail
  module Adapters
    # Writes mail to a folder instead of sending it, so a developer who has not
    # chosen a provider yet can still read what their application sent.
    #
    # This exists because of what happens without it. On a fresh install there
    # is no provider, so asking for an adapter raises ConfigurationError -- and
    # sparrow_auth deliberately swallows every SparrowMail::Error when it sends
    # a sign-in code, because a provider having a bad day must not become a way
    # to find out which addresses have accounts. Both halves of that are right.
    # Together, on the first afternoon, they meant somebody typed their address,
    # read "check your email", and waited for a message that was never sent and
    # never would be. One warning line in the log was the only trace.
    #
    # So this is the floor rather than a feature: with no provider configured,
    # in development, mail lands in tmp/sparrowkit-mail and the loop closes.
    #
    # What it is NOT is a provider. It is not offered in the control panel's
    # list, it does not make the mail badge green, and the panel goes on saying
    # no provider is configured -- because none is, and a page that said
    # otherwise would be lying about whether mail reaches anybody. Choosing a
    # real provider is still the thing to do; this only means nothing is silently
    # lost before you do.
    #
    # Each message is written as a .eml file, which is the format every mail
    # client opens and the format nothing has to be invented for. The control
    # panel reads them back with the same parser.
    class Preview < Base
      adapter_name :preview
      display_name "Preview"

      # Where messages go, relative to the application root.
      DIRECTORY = File.join("tmp", "sparrowkit-mail")

      # Sortable, and with no recipient in it: a filename built from an address
      # is a filename an address can choose.
      #
      # Microseconds rather than milliseconds, because the panel sorts by name
      # and calls the result "newest first". At millisecond resolution two
      # messages sent in the same tick -- a sign-in code and the notice beside
      # it, which is an ordinary pair rather than a contrived one -- tied on the
      # timestamp and were then ordered by the random suffix, so "newest" was
      # a coin toss. The suffix is only there so two processes writing in the
      # same instant cannot land on one filename.
      STAMP = "%Y%m%dT%H%M%S%6N"

      # One message, as the panel reads it back.
      Message = Struct.new(:path, :at, :to, :subject, :text)

      class << self
        # Nothing to be sandboxed from. Saying true keeps the behaviour
        # identical in both modes rather than having the core short-circuit it.
        def native_sandbox? = true

        # Records rather than sends, so there is no reputation to keep apart.
        def reputation_bearing? = false

        # Not a way of getting mail to anybody, so not one to offer on the
        # settings page. See Adapters::Base.provider?.
        def provider? = false

        # Somewhere else to put them, if tmp/ is not where you want them.
        #
        #   SparrowMail::Adapters::Preview.directory = "/tmp/my-mail"
        #
        # Set it to nil to go back to the default.
        attr_writer :directory

        # The folder, as an absolute path.
        #
        # Rails.root when there is a Rails, the working directory otherwise --
        # this gem depends on `mail` alone and works outside Rails, so it cannot
        # ask for Rails.root and assume an answer.
        #
        # Not memoised. Reading it twice costs nothing, and a value cached at
        # the first send would outlive whatever set it.
        def directory
          return File.expand_path(@directory) if @directory

          root = defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root
          File.expand_path(DIRECTORY, root ? root.to_s : Dir.pwd)
        end

        # The most recent messages, newest first.
        #
        # Anything unreadable is skipped rather than shown or raised on. This
        # reads a folder on somebody's development machine, where a half-written
        # file, or something they dropped in by hand, is an ordinary event and
        # neither a reason for the page to be a stack trace nor something to
        # render a blank row for.
        def recent(limit: 25)
          files(limit: limit).filter_map { |path| read(path) }
        end

        def count = files.size

        # Deletes the messages and nothing else.
        #
        # Globs and unlinks rather than removing the folder, because the folder
        # is a configurable path and `rm_rf` on one of those is how a tidy-up
        # button becomes an incident.
        def clear!
          files.each { |path| File.delete(path) }
        end

        def files(limit: nil)
          found = Dir.glob(File.join(directory, "*.eml")).sort.reverse
          limit ? found.first(limit) : found
        end

        def read(path)
          mail = ::Mail.read(path)

          message = Message.new(
            path: path,
            at: File.mtime(path),
            to: Array(mail.to).join(", "),
            subject: mail.subject.to_s,
            text: body_of(mail)
          )

          # Nothing at all came back, so whatever this file is, it is not a
          # message. `mail` parses rather than validates -- handed a run of
          # binary it returns a Message with no recipient, no subject and no
          # body instead of raising -- so a rescue alone would have let a blank
          # row onto the page and called it working.
          return nil if message.to.empty? && message.subject.empty? && message.text.strip.empty?

          message
        rescue
          # Skipped, and deliberately not logged. This gem's first rule is that
          # message bodies are never logged, enforced by exactly one file being
          # allowed to touch a logger -- and every file in this folder IS a
          # body. An adapter that reported what it could not parse would be the
          # one place that rule could be broken by accident.
          nil
        end

        private

        def body_of(mail)
          part = mail.multipart? ? (mail.text_part || mail.html_part) : mail
          part&.decoded.to_s
        end
      end

      def deliver_envelope(envelope)
        FileUtils.mkdir_p(self.class.directory)
        File.write(path_for(envelope), source_of(envelope))

        success_result(envelope, message_id: "preview-#{SecureRandom.hex(8)}")
      rescue SystemCallError => e
        # A folder that cannot be written to is a configuration problem in the
        # only sense this adapter has one, and saying which folder is the whole
        # of the fix.
        raise ConfigurationError,
          "could not write to #{self.class.directory} (#{e.class}). " \
          "That is where mail goes while no provider is configured."
      end

      private

      def path_for(envelope)
        File.join(
          self.class.directory,
          "#{envelope_time.strftime(STAMP)}-#{SecureRandom.hex(3)}.eml"
        )
      end

      def envelope_time = Time.now

      # The message as it was, when there is one to copy.
      #
      # An envelope built straight from SparrowMail.deliver! carries no Mail
      # object, so one is composed from the fields instead -- through Mail
      # rather than by joining strings, so that a header value cannot write a
      # header of its own.
      def source_of(envelope)
        return envelope.mail.to_s if envelope.mail

        mail = ::Mail.new
        mail.from = envelope.from&.to_s
        mail.to = envelope.to.map(&:to_s)
        mail.cc = envelope.cc.map(&:to_s) if envelope.cc.any?
        mail.subject = envelope.subject
        mail.body = envelope.text_body.to_s
        mail.to_s
      end
    end
  end
end
