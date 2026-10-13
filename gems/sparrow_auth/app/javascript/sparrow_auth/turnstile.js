// The Cloudflare Turnstile widget, served at <path_prefix>/turnstile-js and
// loaded by SparrowAuth::Turnstile.widget, which also draws the element this
// looks for:
//
//   <div data-sparrow-auth-turnstile data-sitekey="..." data-action="login"></div>
//
// The widget leaves a token in its form as `cf-turnstile-response`, which the
// server checks with Cloudflare before it sends any mail.
//
// Rendered explicitly rather than by Cloudflare's own page scan, because that
// scan runs once per document and Turbo swaps pages without a new one.
// Cloudflare's script is loaded on first use, from Cloudflare (it must not be
// bundled or proxied), and only on pages that have a widget.
//
// The form's submit buttons wait for a token, so a quick typist cannot send an
// empty one and be told off for it. If the widget cannot load at all -- a
// blocker, Cloudflare down -- the buttons are given back, and the server's
// answer says what went wrong rather than a button that never works.
(function () {
  if (window.SparrowAuthTurnstile) {
    window.SparrowAuthTurnstile.scan();
    return;
  }

  var SCRIPT_URL = "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit";
  var loading = null;

  var load = function () {
    if (window.turnstile) return Promise.resolve(window.turnstile);

    loading = loading || new Promise(function (resolve, reject) {
      var script = document.createElement("script");
      script.src = SCRIPT_URL;
      script.async = true;
      script.onload = function () { resolve(window.turnstile); };
      script.onerror = function () {
        loading = null;
        reject(new Error("Turnstile did not load"));
      };
      document.head.appendChild(script);
    });
    return loading;
  };

  var setSubmittable = function (element, enabled) {
    var form = element.closest("form");
    if (!form) return;

    form.querySelectorAll("[type=submit]").forEach(function (button) {
      button.disabled = !enabled;
    });
  };

  var render = function (element) {
    if (element.hasAttribute("data-sparrow-auth-turnstile-rendered")) return;
    element.setAttribute("data-sparrow-auth-turnstile-rendered", "");

    // A page restored from Turbo's cache still holds the last widget's markup,
    // which is dead. Start from nothing.
    element.replaceChildren();
    setSubmittable(element, false);

    load()
      .then(function (turnstile) {
        if (!element.isConnected) return;

        element.sparrowAuthWidgetId = turnstile.render(element, {
          sitekey: element.getAttribute("data-sitekey"),
          action: element.getAttribute("data-action"),
          appearance: "interaction-only",
          callback: function () { setSubmittable(element, true); },
          "expired-callback": function () { setSubmittable(element, false); },
          "error-callback": function () { setSubmittable(element, true); }
        });
      })
      .catch(function () { setSubmittable(element, true); });
  };

  var scan = function () {
    document.querySelectorAll("[data-sparrow-auth-turnstile]").forEach(render);
  };

  // Before Turbo snapshots the page, take the widgets out so a restored page
  // draws fresh ones.
  document.addEventListener("turbo:before-cache", function () {
    document.querySelectorAll("[data-sparrow-auth-turnstile-rendered]").forEach(function (element) {
      if (window.turnstile && element.sparrowAuthWidgetId !== undefined) {
        window.turnstile.remove(element.sparrowAuthWidgetId);
      }
      element.removeAttribute("data-sparrow-auth-turnstile-rendered");
      element.replaceChildren();
    });
  });
  document.addEventListener("turbo:load", scan);

  window.SparrowAuthTurnstile = { scan: scan };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", scan);
  } else {
    scan();
  }
})();
