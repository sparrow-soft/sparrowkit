# frozen_string_literal: true

# A host application's tenant-scoped controller.
#
# Everything tenancy-related here comes from including one module. The actions
# below are written the way an application would write them — `Widget.all`, with
# no mention of an organization anywhere — which is the point: the scoping has
# to hold for code that never thought about it.
class WidgetsController < ActionController::Base
  include SparrowAuth::Tenancy

  # Deliberately not rescued into a friendly page. A tenancy failure is a bug,
  # and a bug that renders as "no results" is one nobody reports.
  rescue_from SparrowAuth::NotAMember, with: :refuse
  rescue_from SparrowAuth::UnscopedQuery, with: :refuse

  # The three actions below opt out on purpose, and the reason is the same for
  # each: they exist to show that the tenant scope holds on its own. An action
  # that asked for a role as well would refuse first, and then these would prove
  # the check works rather than proving the scope does.
  #
  # rig for the layer below it.
  SCOPE_IS_WHAT_IS_UNDER_TEST =
    "this action exists to show the tenant scope holding without a role check in front of it"

  def index
    render plain: Widget.order(:id).pluck(:name).join(",")
  end

  def create
    widget = Widget.create!(name: params[:name])
    render plain: widget.organization_id.to_s
  end

  # Only admins and above, so the suite can prove the organization role is enforced over HTTP
  # and not merely in the model.
  def destroy_all
    Widget.destroy_all
    render plain: "ok"
  end

  def switch
    # Not an opt-out from deciding: switch_organization! is itself an access
    # decision, and refuses anybody who is not a member of the organization
    # being switched into. It is just not a decision about *this* organization,
    # which is what the after_action counts.
    switch_organization!(SparrowAuth::Organization.find(params[:organization_id]))
    render plain: current_organization.slug
  end

  def whoami
    render plain: current_organization&.slug.to_s
  end

  private

  def refuse
    render plain: "refused", status: :forbidden
  end
end
