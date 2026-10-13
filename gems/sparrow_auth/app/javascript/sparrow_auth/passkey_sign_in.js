// Passkey sign-in, served at <path_prefix>/webauthn-autofill-js in place of
// Rodauth's own script and loaded by rodauth.render("webauthn-autofill").
//
// It does two things with the one challenge that partial renders into
// form#webauthn-login-form:
//
// 1. Autofill. Offers the account's passkeys in the dropdown of any field
//    marked autocomplete="... webauthn" (conditional mediation), exactly as
//    Rodauth's script did.
//
// 2. The button. Any element marked data-sparrow-auth-passkey is shown once
//    the browser can do WebAuthn at all, and a click on it opens the
//    browser's passkey prompt. It asks the server nothing new, so like the
//    autofill it says nothing about which addresses have a passkey.
//
// A browser allows one WebAuthn request at a time, and the autofill request
// waits for as long as the page is open. So the button cancels it first, and
// the cancellation is swallowed rather than left as an unhandled rejection.
//
// Markup, which belongs to the application:
//
//   <button type="button" data-sparrow-auth-passkey hidden>Sign in with a passkey</button>
//   <div data-sparrow-auth-passkey-error hidden>Passkey sign-in didn't work ...</div>
//   <%= rodauth.render("webauthn-autofill") %>
//
// The error element is shown when the prompt fails for a reason other than
// the person cancelling it. Cancelling (NotAllowedError) is silent, because
// the email form beside the button is a complete way in either way.
(function () {
  var form = document.getElementById("webauthn-login-form");
  if (!form || form.hasAttribute("data-sparrow-auth-passkey-ready")) return;
  form.setAttribute("data-sparrow-auth-passkey-ready", "");

  var pack = function (v) {
    return btoa(String.fromCharCode.apply(null, new Uint8Array(v)))
      .replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");
  };
  var unpack = function (v) {
    return Uint8Array.from(atob(v.replace(/-/g, "+").replace(/_/g, "/")), function (c) { return c.charCodeAt(0); });
  };

  var options = function () {
    var opts = JSON.parse(form.getAttribute("data-credential-options"));
    opts.challenge = unpack(opts.challenge);
    opts.allowCredentials.forEach(function (cred) { cred.id = unpack(cred.id); });
    return opts;
  };

  var submit = function (cred) {
    var rawId = pack(cred.rawId);
    var authValue = {
      type: cred.type,
      id: rawId,
      rawId: rawId,
      response: {
        authenticatorData: pack(cred.response.authenticatorData),
        clientDataJSON: pack(cred.response.clientDataJSON),
        signature: pack(cred.response.signature)
      }
    };
    if (cred.response.userHandle) authValue.response.userHandle = pack(cred.response.userHandle);

    document.getElementById("webauthn-auth").value = JSON.stringify(authValue);
    form.submit();
  };

  // A passkey the device offered last time and the server had no record of
  // (see sparrow_auth_note_unknown_passkey in rodauth_main.rb). Tell the
  // device, which may then stop offering it. Read once, then forgotten.
  var unknown = (document.cookie.match(/(?:^|;\s*)sparrow_auth_unknown_passkey=([A-Za-z0-9_-]+)/) || [])[1];
  if (unknown) {
    document.cookie = "sparrow_auth_unknown_passkey=; Max-Age=0; path=/";
    if (window.PublicKeyCredential && PublicKeyCredential.signalUnknownCredential) {
      try {
        var rpId = JSON.parse(form.getAttribute("data-credential-options")).rpId || location.hostname;
        Promise.resolve(PublicKeyCredential.signalUnknownCredential({ rpId: rpId, credentialId: unknown }))
          .catch(function () { /* the device may decline; nothing to do */ });
      } catch (e) { /* never let this stop passkey sign-in below */ }
    }
  }

  if (!window.PublicKeyCredential) return;

  var pending = null;

  var cancelAutofill = function () {
    if (pending) pending.abort();
    pending = null;
  };

  // Turbo keeps the document across visits, so a request left waiting would
  // outlive the page that started it and block the next one.
  document.addEventListener("turbo:before-visit", cancelAutofill, { once: true });
  window.addEventListener("pagehide", cancelAutofill, { once: true });

  var startAutofill = function () {
    if (!PublicKeyCredential.isConditionalMediationAvailable) return;

    PublicKeyCredential.isConditionalMediationAvailable().then(function (available) {
      if (!available || !form.isConnected || pending) return;

      pending = new AbortController();
      navigator.credentials
        .get({ mediation: "conditional", publicKey: options(), signal: pending.signal })
        .then(submit)
        .catch(function () { /* cancelled by the button, or by leaving the page */ });
    });
  };

  startAutofill();

  document.querySelectorAll("[data-sparrow-auth-passkey]").forEach(function (button) {
    button.hidden = false;

    button.addEventListener("click", function (event) {
      event.preventDefault();
      cancelAutofill();

      var error = document.querySelector("[data-sparrow-auth-passkey-error]");
      if (error) error.hidden = true;

      navigator.credentials.get({ publicKey: options() }).then(submit, function (e) {
        // Whatever happened, the email field can offer passkeys again.
        startAutofill();
        if (e && e.name === "NotAllowedError") return;

        if (window.console) console.error("Passkey sign-in failed:", e);
        if (error) error.hidden = false;
      });
    });
  });
})();
