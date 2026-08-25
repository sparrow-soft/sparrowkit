# frozen_string_literal: true

# The dummy mounts unconditionally because exercising the panel is its whole
# job. A real host mounts inside `if Rails.env.development?`, and sparrow_ui's
# own middleware refuses anything that did not arrive on a loopback socket.
Rails.application.routes.draw do
  mount SparrowUi::Engine => "/sparrowkit"
end
