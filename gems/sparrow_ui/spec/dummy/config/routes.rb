# frozen_string_literal: true

# The dummy mounts unconditionally because exercising the engine is its whole
# job. A real host mounts inside `if Rails.env.development?` -- see Task 5.
Rails.application.routes.draw do
  mount SparrowUi::Engine => "/sparrowkit"
end
