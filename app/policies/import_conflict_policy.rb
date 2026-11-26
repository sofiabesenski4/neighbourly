# frozen_string_literal: true

class ImportConflictPolicy < ApplicationPolicy
  def index?
    admin?
  end

  def update?
    admin?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user&.admin?
        scope.all
      else
        scope.none
      end
    end
  end
end
