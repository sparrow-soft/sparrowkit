# frozen_string_literal: true

require "rails_helper"

# The font actually reaches the browser.
#
# The stylesheet is compiled ahead of time and inlined into a <style> tag, and
# an inlined relative url() resolves against the PAGE. So the compiled
# `url(InterVariable.woff2)` asked the host application for
# /InterVariable.woff2 -- ActionController::RoutingError on every console page,
# the log filling up, and the theme silently falling back to a system font.
#
# Nothing failed. The pages rendered, the specs passed, and the only symptom
# was in a log nobody reads and a typeface nobody had seen the correct version
# of. Hence checks on both halves: that the stylesheet still says what the
# layout expects to rewrite, and that the rewritten URL is one the engine
# actually serves.
RSpec.describe "the console font" do
  let(:stylesheet) { File.read(SparrowUi.stylesheet_path) }

  it "ships with the stylesheet" do
    expect(File.exist?(SparrowUi.font_path)).to be(true)
  end

  # If `rake ui:css` ever emits a different form -- quotes, a path prefix --
  # the layout's substitution silently stops matching and the 404 comes back.
  it "is referenced in the compiled stylesheet exactly as the layout expects" do
    expect(stylesheet).to include(SparrowUi::FONT_URL_IN_STYLESHEET)
  end

  it "leaves no relative font URL in what the layout inlines" do
    inlined = stylesheet.sub(SparrowUi::FONT_URL_IN_STYLESHEET, "url(/sparrowkit/inter.woff2)")

    expect(inlined).not_to include(SparrowUi::FONT_URL_IN_STYLESHEET)
    expect(inlined).to include("url(/sparrowkit/inter.woff2)")
  end

  describe "over HTTP", type: :request do
    before { allow(Rails.env).to receive(:development?).and_return(true) }

    it "serves the font from the engine, wherever it is mounted" do
      get "/sparrowkit/inter.woff2"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("font/woff2")
      expect(response.body.bytesize).to eq(File.size(SparrowUi.font_path))
    end

    it "points the page at a URL that resolves, rather than at the host's root" do
      get "/sparrowkit"

      expect(response.body).to include("url(/sparrowkit/inter.woff2)")
      expect(response.body).not_to include("url(InterVariable.woff2)")
    end

    # The gate covers everything under the mount, including this.
    it "is refused when it is not local development" do
      allow(Rails.env).to receive(:development?).and_return(false)

      get "/sparrowkit/inter.woff2"

      expect(response).to have_http_status(:not_found)
    end
  end
end
