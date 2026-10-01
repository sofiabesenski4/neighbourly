# frozen_string_literal: true

class ReportPolicy < ApplicationPolicy
  def index?
    admin?
  end

  def create?
    true
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
