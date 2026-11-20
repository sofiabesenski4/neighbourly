# frozen_string_literal: true

# Admins manage every organization. A member sees and edits their own, and
# nothing else. Only admins add or delete organizations.
class OrganizationPolicy < ApplicationPolicy
  def index?
    admin? || member?
  end

  def show?
    admin? || user&.member_of?(record) || false
  end

  def create?
    admin?
  end

  def update?
    show?
  end

  def destroy?
    admin?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user&.admin?
        scope.all
      elsif user&.member?
        scope.where(id: user.organization_id)
      else
        scope.none
      end
    end
  end
end
