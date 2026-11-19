class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  # A whole http or https address with a host, and nothing else. Anchored at
  # both ends, so a second line can't slip something like "javascript:" past
  # the check. "https://?" has no host, so it doesn't count.
  WEB_ADDRESS = %r{\Ahttps?://[^\s/?#@]+(?:[/?#]\S*)?\z}i
end
