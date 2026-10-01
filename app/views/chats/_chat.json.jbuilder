json.extract! chat, :id, :body, :created_at, :updated_at
json.url chat_url(chat, format: :json)
