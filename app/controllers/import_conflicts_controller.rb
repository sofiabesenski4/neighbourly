# Where admins choose, detail by detail, whether a re-imported row's value
# replaces what a service holds now.
class ImportConflictsController < ApplicationController
  before_action :authenticate_user!
  after_action :verify_authorized

  def index
    authorize ImportConflict
    conflicts = policy_scope(ImportConflict).pending.in_field_order
      .includes(service: [:source, :organization, :address, :document])
    @conflicts_by_service = conflicts.group_by(&:service).sort_by { |service, _| [service.name.downcase, service.id] }
  end

  def approve
    conflict = authorized_conflict
    decide([conflict], notice: "#{conflict.label} for '#{conflict.service.name}' now comes from the import.", &:approve!)
  end

  def reject
    conflict = authorized_conflict
    decide([conflict], notice: "Kept the current #{conflict.label.downcase} for '#{conflict.service.name}'.", &:reject!)
  end

  def approve_all
    service, conflicts = authorized_service_conflicts
    decide(conflicts, notice: "'#{service.name}' now has the import's values.", &:approve!)
  end

  def reject_all
    service, conflicts = authorized_service_conflicts
    decide(conflicts, notice: "Kept the current values for '#{service.name}'.", &:reject!)
  end

  private

  def authorized_conflict
    ImportConflict.find(params[:id]).tap { |conflict| authorize conflict, :update? }
  end

  def authorized_service_conflicts
    authorize ImportConflict, :update?
    service = Service.find(params[:service_id])
    [service, service.import_conflicts.pending.in_field_order.to_a]
  end

  # All of a service's decisions land together, or none do.
  def decide(conflicts, notice:)
    decided = conflicts.any? && ImportConflict.transaction do
      raise ActiveRecord::Rollback unless conflicts.map { |conflict| yield conflict, current_user }.all?

      true
    end
    if decided
      redirect_to import_conflicts_path, notice: notice
    else
      redirect_to import_conflicts_path, alert: "Someone already decided this, or a newer import replaced it."
    end
  rescue ActiveRecord::RecordInvalid => error
    redirect_to import_conflicts_path, alert: "Couldn't use the import's value: #{error.record.errors.full_messages.to_sentence}."
  end
end
