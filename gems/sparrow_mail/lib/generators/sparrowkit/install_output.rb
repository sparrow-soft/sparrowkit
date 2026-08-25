# frozen_string_literal: true

require "fileutils"

module Sparrowkit
  # What an install looks like from the outside.
  #
  # The detail -- every file written, every route, every migration, every line
  # ActiveRecord prints while migrating -- goes to log/sparrowkit-install.log.
  # The terminal gets a heading, a spinner, and one line saying it worked.
  #
  # The detail is not noise in itself; it is noise HERE. A developer running
  # this has not asked to review two hundred lines of file creation, and burying
  # the one instruction that matters underneath them is how a successful install
  # reads like a failure. When something does go wrong the message is short and
  # says what to do, and the log holds everything needed to work out why.
  module InstallOutput
    WIDTH = 72

    # Braille frames: one character wide in every terminal font, unlike the
    # block-drawing spinners that leave a trail on some.
    FRAMES = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

    module_function

    def log_path
      Rails.root.join("log", "sparrowkit-install.log")
    end

    # Runs one module's install with its output captured.
    #
    # Prints the heading before, and the confirmation after -- but only if the
    # block returned. A failure prints nothing reassuring and re-raises, so the
    # rake task can turn it into a message and stop.
    def run(label)
      terminal = $stdout
      log = open_log(label)

      result = spin(terminal, log) { capture(log) { yield } }

      terminal.puts "Installed #{label}"
      terminal.flush
      result
    ensure
      log&.close
    end

    # Everything written to stdout while the block runs goes to the log.
    #
    # Reassigning $stdout rather than passing a shell, because there are three
    # separate writers: Thor's `say_status`, ActiveRecord's migration output,
    # and anything a generator `puts` directly. Thor::Shell::Basic#stdout reads
    # $stdout each time, so all three follow.
    def capture(log)
      original = $stdout
      $stdout = log
      begin
        yield
      ensure
        $stdout = original
      end
    end

    # A spinner on the real terminal while the work happens somewhere else.
    #
    # Skipped entirely when stdout is not a terminal -- a CI log or a piped
    # install would otherwise collect thousands of carriage returns and frames.
    # The log line replaces it there, so the output still says what happened.
    def spin(terminal, log)
      return yield unless terminal.tty?

      running = true
      spinner = Thread.new do
        index = 0
        while running
          terminal.print("\r  #{FRAMES[index % FRAMES.size]}")
          terminal.flush
          sleep 0.08
          index += 1
        end
      end

      begin
        yield
      ensure
        running = false
        spinner.join
        # Carriage return, then clear to end of line, so the spinner leaves
        # nothing behind whether it finished or was interrupted.
        terminal.print("\r\e[2K")
        terminal.flush
        log.flush
      end
    end

    def open_log(label)
      FileUtils.mkdir_p(File.dirname(log_path))
      log = File.open(log_path, "a")
      log.sync = true
      log.puts
      log.puts "== #{label} at #{Time.now.strftime("%Y-%m-%d %H:%M:%S")} ".ljust(WIDTH, "=")
      log
    end

    # Lines a module wants in the closing summary rather than in the log.
    #
    # Almost nothing qualifies. The whole point of this file is that a
    # successful install prints four lines and not two hundred, so the bar is
    # "somebody cannot proceed without knowing this" -- which the seeded account
    # meets, because there is otherwise nobody to sign in as and no way to find
    # out that there is.
    def notes
      @notes ||= []
    end

    def note(line)
      notes << line
    end

    # Whether `sparrowkit:install` is running, as opposed to one module's own
    # install task on its own.
    #
    # It decides who prints the notes. Under the umbrella the summary does, at
    # the end, where a developer is looking; run alone there is no summary, so
    # the module's task prints them itself. Without this the notes were either
    # printed twice or not at all, depending on which of those two was fixed
    # first.
    def umbrella?
      @umbrella == true
    end

    def umbrella!
      @umbrella = true
    end

    def print_notes(terminal = $stdout)
      return if notes.empty?

      terminal.puts
      notes.each { |line| terminal.puts line }
      terminal.puts
    end

    # Set by the application template before it calls the install task, and
    # inherited by that subprocess.
    #
    # It answers a question nothing else can: where the developer's SHELL will
    # be when this finishes. After `rails new blog` they are back in the parent
    # directory and need `cd blog`; after `bin/rails app:template` they are
    # already inside the application and `cd blog` would fail. The process's own
    # working directory cannot tell the two apart -- it is the application root
    # either way.
    FRESH_APP_ENV = "SPARROWKIT_FRESH_APP"

    def fresh_app?
      ENV[FRESH_APP_ENV] == "1"
    end

    def app_directory
      Rails.root.basename.to_s
    end

    # The last thing a successful `sparrowkit:install` prints.
    def summary(terminal = $stdout)
      steps = []
      steps << "cd #{app_directory}" if fresh_app?

      # Saying where sign-in lives is not optional. SparrowKit ships no sign-in
      # page of its own, so an install that stopped at "run the server" left
      # somebody looking for one with nothing on screen saying where it is.
      steps << "sign in at /auth/login, which Rodauth serves; the pages your customers see are yours to write"
      steps << "run bin/rails server"
      steps << "open http://localhost:3000/sparrowkit in your browser"

      log = fresh_app? ? "#{app_directory}/log/sparrowkit-install.log" : "log/sparrowkit-install.log"

      terminal.puts
      terminal.puts "=== SparrowKit is installed. ==="
      terminal.puts
      terminal.puts "Next steps:"
      terminal.puts
      steps.each_with_index { |step, index| terminal.puts "#{index + 1}. #{step}" }

      print_notes(terminal)

      terminal.puts
      terminal.puts "Installation details are in #{log}"
      terminal.puts
      terminal.puts "Happy coding. :)"
      terminal.puts
    end
  end
end
