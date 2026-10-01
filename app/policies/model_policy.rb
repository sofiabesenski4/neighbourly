# frozen_string_literal: true

class ModelPolicy < ApplicationPolicy
  def index?
    admin?
  end

  def show?
    admin?
  end

  def refresh?
    admin?
  end
end
