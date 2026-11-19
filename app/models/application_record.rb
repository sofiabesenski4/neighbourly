class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  # A whole http or https address and nothing else. Anchored at both ends, so a
  # second line can't slip something like "javascript:" past the check.
  WEB_ADDRESS = %r{\Ahttps?://\S+\z}i
end
