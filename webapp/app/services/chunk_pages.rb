# frozen_string_literal: true

# The pages a text chunk spans, and which of them a passage of it falls on.
#
# Chunks are cut by length, not at page breaks, so one chunk can begin on the last line of a page
# and carry on through the next. Every chunk with a page has `page_ss`, the page it starts on. A
# chunk that crosses a page break also has every page it touches in `pages_ism`, and in
# `page_start_offsets_ism` the character offset within `chunk_text_tesi` at which each of those
# pages begins, in the same order:
#
#   page_ss:                "91"
#   pages_ism:              [91, 92]
#   page_start_offsets_ism: [0, 4]     # "91 \n\nCulture requirement..." -- page 92 starts at 4
module ChunkPages
  START_PAGE_FIELD = "page_ss"
  PAGES_FIELD = "pages_ism"
  OFFSETS_FIELD = "page_start_offsets_ism"
  FIELDS = [ START_PAGE_FIELD, PAGES_FIELD, OFFSETS_FIELD ].freeze

  MARK = %r{</?mark>}
  ELLIPSIS = "…"

  module_function

  # @return [Array<Integer>] every page the chunk spans, in order; empty when none were indexed
  def pages(chunk)
    pages = Array(chunk[PAGES_FIELD]).presence || Array(chunk[START_PAGE_FIELD])
    pages.filter_map { |page| Integer(page.to_s, 10, exception: false) }
  end

  # Whether the chunk crosses a page break, so that finding the page of a passage needs its text.
  def multiple?(chunk)
    pages(chunk).length > 1
  end

  # The page an excerpt of the chunk falls on: the page holding its first highlighted word, or
  # where there is none, the middle of the excerpt. Falls back to the chunk's first page when the
  # excerpt cannot be found in the text.
  #
  # @param chunk [Hash, SolrDocument] carrying PAGES_FIELD and OFFSETS_FIELD
  # @param snippet [String] the excerpt: HTML-escaped, possibly with <mark>s and a trailing "…"
  # @param text [String, nil] the chunk's full text, as stored in chunk_text_tesi
  # @return [Integer, nil] nil when the index recorded no page
  def page_for(chunk, snippet:, text:)
    pages = pages(chunk)
    offsets = Array(chunk[OFFSETS_FIELD]).map(&:to_i)
    return pages.first if pages.length < 2 || offsets.length != pages.length

    position = position_in(text.to_s, snippet.to_s)
    return pages.first unless position

    pages[offsets.rindex { |offset| offset <= position } || 0]
  end

  # "page 91", or "pages 91–92" for a chunk that crosses a page break.
  def label(pages)
    pages = Array(pages)
    return if pages.empty?

    pages.length == 1 ? "page #{pages.first}" : "pages #{pages.first}–#{pages.last}"
  end

  # Where in the text the snippet's first highlight begins. A snippet without highlights (one that
  # matched by meaning) is placed by its middle instead, so the page holding most of it wins over
  # a page whose last line happens to open the chunk.
  def position_in(text, snippet)
    unescaped = CGI.unescapeHTML(snippet.delete_prefix(ELLIPSIS).delete_suffix(ELLIPSIS))
    fragment = unescaped.gsub(MARK, "")
    return if text.empty? || fragment.strip.empty?

    start = text.index(fragment)
    return unless start

    start + (unescaped.include?("<mark>") ? unescaped.split(MARK, 2).first.length : fragment.length / 2)
  end
  private_class_method :position_in
end
