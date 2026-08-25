# frozen_string_literal: true

Rails.application.routes.draw do
  mount SparrowAuth::Engine => "/auth"
  mount SparrowPay::Engine => "/billing"

  # The developer console, and the payments control panel sparrow_pay registers
  # with it.
  #
  # ONE mount, at /sparrowkit, with every panel nested below it. A sibling mount
  # at /console/pay would not pass through sparrow_ui's engine middleware, so it
  # would also skip the gate it was relying on someone else to prove.
  #
  # Mounted unconditionally because exercising the panel is part of this dummy's
  # job, and a guard on `Rails.env.development?` would put it out of reach of
  # the request specs, which run in the test environment. A real host mounts it
  # inside that guard; either way sparrow_ui's own engine middleware refuses
  # anything that is not local development arriving on a loopback socket, and it
  # runs ahead of every route below the mount.
  mount SparrowUi::Engine => "/sparrowkit" if defined?(SparrowUi::Engine)
end
