# frozen_string_literal: true

# Admins manage every service. A member sees, adds, edits and deletes their
# organization's services, and nothing else. A service a member adds always
# belongs to their organization. Imported services are closed, not deleted.
class ServicePolicy < ApplicationPolicy
  def index?
    admin? || member?
  end

  def show?
    admin? || user&.member_of?(record) || false
  end

  def create?
    admin? || member?
  end

  def update?
    show?
  end

  # Only a service added on this site can be deleted. An imported one would
  # come back with the next import, and its row would stay searchable in
  # chat. Closing it hides it from both. An admin can remove the imported row
  # from its source instead.
  def destroy?
    show? && record.document_id.nil?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user&.admin?
        scope.all
      elsif user&.member?
        scope.where(organization_id: user.organization_id)
      else
        scope.none
      end
    end
  end
end
