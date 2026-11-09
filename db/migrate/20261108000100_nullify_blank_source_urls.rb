# Uploads without a URL were saved with an empty string. The unique index on
# url allows only one of those, so a second URL-less source failed to save.
# Source now stores blank URLs as NULL, which the index allows many of.
class NullifyBlankSourceUrls < ActiveRecord::Migration[8.1]
  def up
    execute "UPDATE sources SET url = NULL WHERE btrim(url) = ''"
  end

  def down
    # Nothing to restore. NULL and an empty string mean the same here.
  end
end
