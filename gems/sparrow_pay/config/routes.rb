# frozen_string_literal: true

# Nothing.
#
# SparrowKit serves no end-user pages in production, and billing is the most
# application-specific screen there is -- your plan names, your copy, your
# upgrade argument. What this gem does is hold your processor's credentials and
# wire Pay up so that `organization.payment_processor` works; the checkout, the
# portal and the page your customer reads are yours, built on Pay's own API.
#
# Pay's webhook routes are Pay's, mounted by Pay, and are unaffected by this.
SparrowPay::Engine.routes.draw do
end
