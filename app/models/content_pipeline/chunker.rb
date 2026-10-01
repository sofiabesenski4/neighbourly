module ContentPipeline
  class Chunker
    MAX_CHUNK_LENGTH = 1500 # characters (~375 tokens)
    OVERLAP_LENGTH = 200  # characters of overlap between chunks

    def self.call(text, max_chunk_length: MAX_CHUNK_LENGTH, overlap_length: OVERLAP_LENGTH)
      return [text] if text.length <= max_chunk_length

      chunks = []
      position = 0

      while position < text.length
        chunk = text[position, max_chunk_length]

        if position + max_chunk_length < text.length
          last_break = chunk.rindex(/[.!?\n]/)
          chunk = chunk[0..last_break] if last_break && last_break > max_chunk_length / 2
        end

        chunks << chunk.strip if chunk.strip.present?
        advance = chunk.length - overlap_length
        break if advance <= 0
        position += advance
      end

      chunks
    end
  end
end
