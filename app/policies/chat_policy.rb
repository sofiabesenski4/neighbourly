# frozen_string_literal: true

class ChatPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def show?
    admin? || owner?
  end

  def create?
    user.present?
  end

  def new?
    create?
  end

  def update?
    admin? || owner?
  end

  def edit?
    update?
  end

  def destroy?
    admin? || owner?
  end

  private

  def owner?
    user.present? && record.user_id == user.id
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user&.admin?
        scope.all
      elsif user.present?
        scope.where(user_id: user.id)
      else
        scope.none
      end
    end
  end
end
