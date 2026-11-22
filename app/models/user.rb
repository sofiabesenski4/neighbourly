class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
    :recoverable, :rememberable, :validatable

  has_many :chats, dependent: :destroy
  has_many :reports, dependent: :destroy
  # A member keeps their organization's details and services up to date.
  # Admins choose who is a member of what.
  belongs_to :organization, optional: true

  def admin?
    admin
  end

  def member?
    organization_id.present?
  end

  # True for the organization this user is a member of, and for a service it
  # offers.
  def member_of?(record)
    return false unless member?

    case record
    when Organization then record.id == organization_id
    when Service then record.organization_id == organization_id
    else false
    end
  end
end
