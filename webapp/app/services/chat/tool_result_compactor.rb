# frozen_string_literal: true

require "set"

module Chat
  # Produces bounded, deduplicated evidence text for the model while preserving ranked order.
  class ToolResultCompactor
    MAX_CHARACTERS = 24_000
    MAX_TOTAL_CHARACTERS = 40_000
    # The indexer cuts chunks at about 1,500 characters, so this only guards against outliers. A lower
    # cap drops the end of nearly every chunk, which is where a list running into the next chunk is.
    MAX_EXCERPT_CHARACTERS = 2_000
    # Neighbouring chunks repeat some text; shorter matches are treated as coincidence.
    MIN_OVERLAP_CHARACTERS = 20
    MAX_ITEMS_PER_TYPE = 20
    MAX_CHUNKS_PER_RESULT = 1
    DUPLICATE_EVIDENCE_TEXT = "No new evidence; these results duplicate evidence already returned."
    BUDGET_REACHED_TEXT = "Evidence budget reached; answer using the evidence already returned."
    OMITTED_EVIDENCE_TEXT = "[Additional evidence omitted to keep the prompt bounded.]"

    def initialize(character_budget: MAX_TOTAL_CHARACTERS)
      @seen = Set.new
      @remaining_characters = character_budget
    end

    def call(result)
      return result[:text].to_s.first(MAX_CHARACTERS) if result[:error]
      # Checked before the sections are built so that exhausting the budget cannot mark evidence as
      # seen without ever sending it.
      return BUDGET_REACHED_TEXT if @remaining_characters <= 0

      content = result[:structured_content].to_h.deep_symbolize_keys
      @room = [ MAX_CHARACTERS, @remaining_characters ].min
      @room_exhausted = false
      sections = [
        passage_text(content[:passages]),
        catalog_text(content[:results]),
        document_text(content)
      ].compact_blank
      text = if evidence_content?(content)
        sections.join("\n\n")
      else
        result[:text].to_s
      end
      consume(bound(annotate(text)))
    end

    private

    # Distinguishes "everything here was already sent" from "what is left did not fit", and tells the
    # model when a result was cut short so it knows more evidence exists.
    def annotate(text)
      return @room_exhausted ? BUDGET_REACHED_TEXT : DUPLICATE_EVIDENCE_TEXT if text.blank?
      return "#{text}\n#{OMITTED_EVIDENCE_TEXT}" if @room_exhausted

      text
    end

    def evidence_content?(content)
      content.key?(:passages) || content.key?(:results) || content.key?(:chunks)
    end

    def passage_text(passages)
      passages = Array(passages).first(MAX_ITEMS_PER_TYPE).map(&:deep_symbolize_keys)
      entries = contiguous_runs(passages).filter_map do |run|
        entry_for(run.map { |passage| chunk_key(passage) }) do
          passage = run.first
          source = passage[:document_title] || passage[:document_id] || "Unknown document"
          <<~TEXT.strip
            #{run.pluck(:rank).compact.sort.join(', ')}. #{source}#{location_text(run_location(run))}
            #{stitched_text(run)}
            Source: #{passage[:url]}
          TEXT
        end
      end
      "Passage evidence:\n#{entries.join("\n\n")}" if entries.any?
    end

    def catalog_text(results)
      entries = Array(results).first(MAX_ITEMS_PER_TYPE).filter_map do |result|
        result = result.deep_symbolize_keys
        document_key = [ :document, result[:id] ]
        chunks = matched_chunk_candidates(result)
        next if @seen.include?(document_key) && chunks.empty?

        lines = [ result[:title] || result[:id] || "Untitled" ]
        lines << "Authors: #{Array(result[:authors]).join(', ')}" if result[:authors].present?
        lines << "Collection: #{result[:collection]}" if result[:collection].present?
        lines << "Matched passages:\n#{chunks.pluck(:line).join("\n")}" if chunks.any?
        lines << "Source: #{result[:url]}" if result[:url].present?
        entry = lines.join("\n")
        next unless reserve_room(entry)

        @seen << document_key
        chunks.each { |chunk| @seen << chunk[:key] }
        entry
      end
      "Catalog evidence:\n#{entries.join("\n\n")}" if entries.any?
    end

    # Lazy so that a chunk beyond the per-result cap is never marked as seen, which would drop it
    # from every later tool result too.
    def matched_chunk_candidates(result)
      Array(result[:matched_chunks]).lazy.filter_map do |chunk|
        chunk = chunk.deep_symbolize_keys
        key = chunk_key(chunk, document_id: result[:id])
        next if @seen.include?(key)

        { key: key, line: "-#{location_text(chunk)} #{excerpt(chunk[:text])}" }
      end.first(MAX_CHUNKS_PER_RESULT)
    end

    def document_text(content)
      return if content[:document_id].blank? || content[:chunks].blank?

      document_id = content[:document_id]
      chunks = Array(content[:chunks]).first(MAX_ITEMS_PER_TYPE).map(&:deep_symbolize_keys)
      chunks = contiguous_runs(chunks, document_id:).filter_map do |run|
        entry_for(run.map { |chunk| chunk_key(chunk, document_id:) }) do
          "#{location_text(run_location(run))}\n#{stitched_text(run)}"
        end
      end
      return if chunks.empty?

      coverage = "#{content[:returned_chunks]} of #{content[:total_chunks]} chunks"
      lines = [ "Document #{content[:document_id]}: #{coverage} (complete: #{content[:complete]})", chunks.join("\n\n") ]
      lines << "Continue with cursor: #{content[:next_cursor]}" if content[:next_cursor].present?
      lines.join("\n\n")
    end

    # Yields only for evidence that is both new and small enough to fit in what is left of this
    # message, and marks its chunks seen only once they are really being sent.
    def entry_for(keys)
      return if keys.all? { |key| @seen.include?(key) }

      entry = yield
      return if entry.blank? || !reserve_room(entry)

      @seen.merge(keys)
      entry
    end

    # Groups unseen chunks that sit next to each other in the same file, in the order their best-ranked
    # member arrived. A chunk cut by length often ends mid-list, and the rest of the list is in the
    # next chunk; sent apart, each half reads as if it were complete.
    #
    # @return [Array<Array<Hash>>] runs of chunks, each in file order
    def contiguous_runs(items, document_id: nil)
      positioned = items.uniq { |item| chunk_key(item, document_id:) }
        .reject { |item| @seen.include?(chunk_key(item, document_id:)) }
        .each_with_index.to_a
      positioned.group_by { |item, position| stitchable?(item) ? item[:filename] : position }
        .values
        .flat_map do |group|
          group.sort_by { |item, _position| item[:chunk_index].to_i }
            .slice_when { |(earlier, _), (later, _)| later[:chunk_index] != earlier[:chunk_index] + 1 }
            .to_a
        end
        .sort_by { |run| run.map(&:last).min }
        .map { |run| run.map(&:first) }
    end

    def stitchable?(item)
      item[:filename].present? && item[:chunk_index].is_a?(Integer)
    end

    def run_location(run)
      { filename: run.first[:filename], pages: run.flat_map { |item| Array(item[:pages]) }.uniq }
    end

    def stitched_text(run)
      run.map { |item| excerpt(item[:text]) }.reduce { |earlier, later| join_overlapping(earlier, later) }
    end

    # Neighbouring chunks overlap, so the start of one repeats the end of the one before it.
    def join_overlapping(earlier, later)
      longest = [ earlier.length, later.length ].min
      overlap = longest.downto(MIN_OVERLAP_CHARACTERS).find { |length| earlier.end_with?(later[0, length]) }
      overlap ? earlier + later[overlap..] : "#{earlier}\n#{later}"
    end

    # Evidence that does not fit is left unseen so a later tool result can carry it, rather than
    # being remembered and then truncated away by #bound.
    def reserve_room(entry)
      if entry.length > @room
        @room_exhausted = true
        return false
      end

      @room -= entry.length
      true
    end

    # One chunk reaches the model as a passage, as a catalog result's matched chunk, and as a
    # document chunk, each shaped differently. Identity is keyed on the filename first because a
    # catalog result's id is not always the document id its chunks carry.
    def chunk_key(chunk, document_id: nil)
      return [ :chunk, chunk[:filename], chunk[:chunk_index] ] if chunk[:filename].present?

      chunk_id = chunk[:chunk_id] || chunk[:id]
      return [ :chunk, chunk_id ] if chunk_id.present?

      [ :chunk, document_id || chunk[:document_id], chunk[:chunk_index], chunk[:pages] ]
    end

    def location_text(item)
      values = [
        item[:filename],
        ChunkPages.label(item[:pages])
      ].compact
      values.any? ? " (#{values.join(', ')})" : ""
    end

    def excerpt(text)
      text.to_s.truncate(MAX_EXCERPT_CHARACTERS, omission: "…")
    end

    def bound(text)
      limit = [ MAX_CHARACTERS, @remaining_characters ].min
      return text if text.length <= limit

      "#{text.first(limit)}\n[Additional evidence omitted to keep the prompt bounded.]"
    end

    def consume(text)
      @remaining_characters -= text.length
      text
    end
  end
end
