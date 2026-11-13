# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChunkPages do
  # Chunk 111 of the Wasow oral history (rj539vs3564): it opens with the "91" footer carried over
  # from the previous chunk, and everything after it is on page 92.
  let(:text) { "91 \n\nCulture requirement--each of them was supposed to include the core list. " \
               "I did get a call from John Searle, who had been asked by the New York Review of Books." }
  let(:chunk) { { "pages_ism" => [ 91, 92 ], "page_start_offsets_ism" => [ 0, 4 ] } }

  describe ".pages" do
    it "reads every page the chunk spans, in order" do
      expect(described_class.pages(chunk)).to eq([ 91, 92 ])
    end

    it "reads the start page of a chunk on a single page, which has no pages_ism" do
      expect(described_class.pages({ "page_ss" => "93" })).to eq([ 93 ])
    end

    it "drops a page that is not a page number, which the viewer could not open at" do
      expect(described_class.pages({ "page_ss" => "iv" })).to eq([])
    end

    it "is empty when the index recorded no page" do
      expect(described_class.pages({})).to eq([])
    end
  end

  describe ".page_for" do
    it "finds the page of the first highlighted word" do
      snippet = "I did get a call from John Searle, who had been asked by the <mark>New</mark> <mark>York</mark>…"

      expect(described_class.page_for(chunk, snippet:, text:)).to eq(92)
    end

    it "places a snippet without highlights by its middle, not by the footer that opens the chunk" do
      snippet = "91 \n\nCulture requirement--each of them was supposed to include the core list.…"

      expect(described_class.page_for(chunk, snippet:, text:)).to eq(92)
    end

    it "keeps a highlight before the page break on the earlier page" do
      chunk = { "pages_ism" => [ 91, 92 ], "page_start_offsets_ism" => [ 0, 60 ] }
      snippet = "91 \n\n<mark>Culture</mark> requirement"

      expect(described_class.page_for(chunk, snippet:, text:)).to eq(91)
    end

    it "matches snippets whose text the highlighter HTML-escaped" do
      text = "Page one. AT&T \"said\" so on page two."
      chunk = { "pages_ism" => [ 1, 2 ], "page_start_offsets_ism" => [ 0, 10 ] }

      expect(described_class.page_for(chunk, snippet: "<mark>AT&amp;T</mark> &quot;said&quot;", text:)).to eq(2)
    end

    it "falls back to the first page when the snippet is not in the text" do
      expect(described_class.page_for(chunk, snippet: "<mark>elsewhere</mark>", text:)).to eq(91)
    end

    it "falls back to the first page without the chunk's text" do
      expect(described_class.page_for(chunk, snippet: "<mark>Searle</mark>", text: nil)).to eq(91)
    end

    it "falls back to the first page when the offsets do not line up with the pages" do
      chunk = { "pages_ism" => [ 91, 92 ], "page_start_offsets_ism" => [ 0 ] }

      expect(described_class.page_for(chunk, snippet: "John <mark>Searle</mark>", text:)).to eq(91)
    end

    it "is nil when the index recorded no page" do
      expect(described_class.page_for({}, snippet: "text", text:)).to be_nil
    end
  end

  describe ".label" do
    it "names one page or the range a chunk spans" do
      expect([ described_class.label([ 91 ]), described_class.label([ 91, 92 ]), described_class.label([]) ])
        .to eq([ "page 91", "pages 91–92", nil ])
    end
  end
end
