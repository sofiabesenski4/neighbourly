# frozen_string_literal: true

class ChatPolicy < ApplicationPolicy
  def show?
    if user.is_a?(GuestChatSession)
      user.owns?(record)
    else
      !record.guest? && (admin? || owner?)
    end
  end

  def create?
    user.present?
  end

  def new?
    create?
  end

  def update?
    show?
  end

  def edit?
    update?
  end

  def destroy?
    show?
  end

  private

  def owner?
    user.present? && record.user_id == user.id
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.is_a?(GuestChatSession)
        user.chats(scope)
      elsif user&.admin?
        scope.where.not(user_id: nil)
      elsif user.present?
        scope.where(user_id: user.id)
      else
        scope.none
      end
    end
  end
end
