class ChatResponseRecovery
  QUEUE_WAIT_LIMIT = 2.minutes
  QUEUED_TIMEOUT_MESSAGE = "This reply didn't start in time. Your question is saved; you can retry it.".freeze
  INTERRUPTED_MESSAGE = "This reply was interrupted. Your question is saved; you can retry it.".freeze

  def self.call(chat)
    chat.with_lock do
      chat.chat_responses.active.each do |response|
        response.with_lock do
          next unless response.active?
          next if response.heartbeat_at > stale_after(response).ago

          cancelled = response.cancelling?
          message = response.queued? ? QUEUED_TIMEOUT_MESSAGE : INTERRUPTED_MESSAGE
          response.update!(
            status: cancelled ? "cancelled" : "failed",
            error_message: cancelled ? nil : message,
            finished_at: Time.current,
            heartbeat_at: Time.current
          )
        end
      end
    end
  end

  def self.stale_after(response)
    # Treat a long queue wait as a deadline too, so lost in-memory jobs cannot
    # leave a conversation occupied indefinitely after a server restart.
    return QUEUE_WAIT_LIMIT if response.queued?

    # A live provider may send no chunks while it reasons or retries a request.
    # Do not expire that work before the configured network timeout can elapse.
    timeout = RubyLLM.config.request_timeout.to_f
    attempts = RubyLLM.config.max_retries.to_i + 1
    [5.minutes, timeout * attempts + 1.minute].max
  end
  private_class_method :stale_after
end
