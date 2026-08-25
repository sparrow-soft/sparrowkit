# frozen_string_literal: true

# A host application's controller behind the permission gate.
#
# Most of what is here would be a mistake in a real application, and that is the
# point: each action is one way of getting authorization wrong, written exactly
# the way somebody writes it when they have not thought about it. The suite
# drives every one of them and asks that it fail rather than serve.
class ProjectsController < ActionController::Base
  include SparrowAuth::Tenancy

  # One include. Authorization includes Tenancy, so there is no arrangement in
  # which organization the request belongs to.

  rescue_from SparrowAuth::NotAMember, with: :deny

  def show
    render plain: current_role.to_s
  end

  def upload
    render plain: "uploaded"
  end

  def destroy
    render plain: "deleted"
  end

  # No check, no opt-out. Nothing about it looks wrong.
  def forgotten
    render plain: Project.find(params[:id]).name
  end

  # Deciding what to draw is not deciding what to allow, so this still counts as
  # unguarded and must still raise.
  def peeked
    render plain: may?(at_least: :admin).to_s
  end

  def public_page
    render plain: "public"
  end

  # An opt-out with nothing said. If this were accepted, "skip_authorization!"
  # would become a line people type to make the error go away.
  def blank_skip
    render plain: "public"
  end

  # A check naming no requirement has decided nothing, and must not be able to
  # pass for a decision.
  def unnamed_requirement
    render plain: "never reached"
  end

  # Two requirements in one call has no reading that is obviously right.
  def both_requirements
    render plain: "never reached"
  end

  # A typo, not a refusal. A role nothing declares would otherwise deny
  # everybody forever, which is indistinguishable from working security.
  def misspelt_role
    render plain: "never reached"
  end

  def misspelt_permission
    render plain: "never reached"
  end

  # The same typo asked of the drawing side. A view that silently hides a button
  # forever because of a misspelling looks exactly like a view that meant to.
  def misspelt_role_in_a_view
    render plain: may?(at_least: :administrator).to_s
  end

  private

  def deny
    render plain: "denied", status: :forbidden
  end
end
