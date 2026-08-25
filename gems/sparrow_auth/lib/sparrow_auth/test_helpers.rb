# frozen_string_literal: true

# Signing in, from your own tests.
#
# Not required by the gem. Require it from your test helper, the way Devise's
# test helpers are required, so that nothing capable of establishing a session
# is ever loaded by a running application:
#
#   # test/test_helper.rb
#   require "sparrow_auth/test_helpers"
#
# Both helpers are called `sign_in`, deliberately, so that moving an assertion
# between an integration test and a system test does not mean rewriting how it
# signs in.
#
# Neither one takes a shortcut. Both request a real code, read it out of the
# mail the way a person would, and redeem it — so the session a test runs under
# is a row in the active-sessions table, revocable and visible on your sessions
# screen, exactly like a session anybody else gets. A helper that forged a
# session instead would be the one code path in the suite that never proves
# sign-in works, and the first thing to keep passing after sign-in breaks.
#
# THE SCREEN IT DRIVES IS YOURS. SparrowKit serves no sign-in page; the one it
# posts to is the one the application wrote into
# your application, at /sign-in. That is the point rather than an inconvenience
# — every test that signs in is now also a test that your sign-in screen works.
# If you moved the screen, set SparrowAuth.config.sign_in_path to wherever it
# went and these follow it.
module SparrowAuth
  module TestHelpers
    # The flow itself, over HTTP, in the test process. Shared by both helpers.
    module Flow
      private

      # Runs the real emailed-code flow against `http` — an
      # ActionDispatch::Integration::Session — and leaves it holding the
      # session cookie.
      def sparrow_auth_run_otp_flow(account, http)
        email = account.respond_to?(:email) ? account.email : account.to_s

        before = SparrowMail.readable_deliveries.size

        sparrow_auth_post(http, SparrowAuth.config.sign_in_path, email: email)

        mail = SparrowMail.readable_deliveries.first
        raise SparrowAuth::Error, sparrow_auth_no_mail_message(email) if mail.nil? ||
          SparrowMail.readable_deliveries.size == before

        code = mail.text[/\b(\d{6})\b/, 1]
        raise SparrowAuth::Error, "no six-digit code in the sign-in mail for #{email}" if code.nil?

        sparrow_auth_post(http, SparrowAuth.config.sign_in_code_path, code: code)

        # Redeeming refuses by sending you back to the same form, so a refusal
        # and a success are both redirects. Left unchecked, a helper that
        # failed to sign anybody in would hand the test a signed-out session
        # and let it fail somewhere else entirely.
        if http.response.location.to_s.end_with?(SparrowAuth.config.sign_in_code_path)
          raise SparrowAuth::Error,
            "the code issued for #{email} was refused. A code is good for one " \
            "browser and ten minutes; check that nothing else redeemed or " \
            "reissued one for this address in the same test."
        end

        http
      end

      # The code is read out of SparrowMail.readable_deliveries, which answers
      # whichever store is live -- envelopes in memory under the test adapter,
      # .eml files under the preview one.
      #
      # This read ActionMailer::Base.deliveries until 0.1.0, and that array is
      # empty in every application that installs the way we tell people to:
      # SparrowKit's installer points ActionMailer at sparrow_mail in every
      # environment, and sparrow_mail's railtie then picks its own adapter. The
      # helper could not have worked for a buyer on any version.
      #
      # Posting to a screen that might not be there.
      #
      # Since 0.1.0 the sign-in screen belongs to the application rather than to
      # the engine, so the first thing a new installation hits is a routing
      # error naming a path nobody wrote — which reads like a bug in this helper
      # rather than a generator that has not been run yet.
      def sparrow_auth_post(http, path, params)
        http.post path, params: params
      rescue ActionController::RoutingError
        raise SparrowAuth::Error,
          "nothing is routed at #{path}, so there is no sign-in screen to sign " \
          "in through. SparrowKit ships no sign-in page — write one, or point " \
          "SparrowAuth.config.sign_in_path at Rodauth's own at /auth/login."
      end

      # The two ways this fails are worth telling apart on sight, because both
      # look identical from the test's side — no mail arrived — and the fixes
      # have nothing to do with each other.
      def sparrow_auth_no_mail_message(email)
        account = SparrowAuth::Account.find_by_email(email)

        if account.nil?
          "no sign-in code was delivered for #{email}, and no account has that " \
          "address. Create the account first, or turn on signup_with_code."
        elsif !account.verified?
          "no sign-in code was delivered for #{email}: the account exists but " \
          "its address has never been verified, and an unverified address is " \
          "not signed in by code. Create the account verified in your fixture " \
          "or factory."
        else
          "no sign-in code was delivered for #{email}. The usual cause is the " \
          "rate limit — one code per address per minute — which means this " \
          "test signed the same address in twice. Give each test its own " \
          "address."
        end
      end
    end

    # For ActionDispatch::IntegrationTest.
    #
    #   class PostsTest < ActionDispatch::IntegrationTest
    #     include SparrowAuth::TestHelpers::Integration
    #
    #     test "the index" do
    #       sign_in accounts(:owner)
    #       get "/posts"
    #       assert_response :success
    #     end
    #   end
    module Integration
      include Flow

      def sign_in(account)
        sparrow_auth_run_otp_flow(account, self)
        follow_redirect! if response.redirect?
        account
      end
    end

    # For ActionDispatch::SystemTestCase.
    #
    #   class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
    #     include SparrowAuth::TestHelpers::System
    #   end
    #
    # The flow runs over HTTP rather than through the browser, and the session
    # cookie it produces is handed to the browser. Capybara's server is this
    # same process, so that cookie is one the application will accept.
    #
    # Driving the two forms with Capybara instead is slower and, on Chrome,
    # flaky: submitting them is a plain browser navigation — the generated pages
    # carry no JavaScript — and chromedriver returns from the click as soon as
    # it has dispatched it, which can be before the new document has committed.
    # Any query that resolves a node in that window, `assert_text` included, can
    # have the document swapped underneath it, and Chrome reports that as a raw
    # "Node with given id does not belong to the document" inspector error
    # rather than the stale-element error Capybara knows to retry.
    module System
      include Flow

      # Signs the browser in and leaves it on `redirect_to` (the configured
      # landing path by default).
      def sign_in(account, redirect_to: SparrowAuth.config.after_accept_path)
        http = ActionDispatch::Integration::Session.new(Rails.application)
        http.host = Capybara.current_session.server.host
        sparrow_auth_run_otp_flow(account, http)

        # A cookie can only be set for the page the browser is on, so it has to
        # be somewhere on the application first. The sign-in page is the one it
        # has just proved is there, and it costs nothing to render.
        visit SparrowAuth.config.sign_in_path

        http.cookies.to_hash.each do |name, value|
          # Rack::Test's jar hands back the unescaped value; a browser stores
          # and sends the escaped form, which is the one the application
          # decrypts.
          page.driver.browser.manage.add_cookie(
            name: name, value: Rack::Utils.escape(value), path: "/"
          )
        end

        visit redirect_to
        account
      end
    end
  end
end
