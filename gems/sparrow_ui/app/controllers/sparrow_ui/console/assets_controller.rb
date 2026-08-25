# frozen_string_literal: true

module SparrowUi
  module Console
    # The one binary the console serves: the Inter variable font.
    #
    # Served by the engine rather than through the host's asset pipeline,
    # because there may not be one. The whole console is built to render on an
    # application thirty seconds old, before anything is configured, which is
    # why the stylesheet is inlined rather than linked -- and a font cannot be
    # inlined the same way without adding 456KB of base64 to every page.
    #
    # No gate here. sparrow_ui's engine middleware refused anything that was not
    # local development before routing ran, and it covers this too.
    class AssetsController < ActionController::Base
      def font
        # `send_file` rather than reading it in: it hands the descriptor to the
        # web server where one can take it, and streams rather than allocating
        # 342KB per request.
        send_file SparrowUi.font_path,
          type: "font/woff2",
          disposition: "inline",
          # A year, because the file never changes without the gem changing,
          # and a console page is reloaded constantly while somebody is filling
          # the forms in. Immutable so a browser does not even revalidate.
          #
          # Development only, so there is no cache to poison anywhere real: the
          # engine is not in a production bundle.
          headers: {"Cache-Control" => "public, max-age=31536000, immutable"}
      end
    end
  end
end
