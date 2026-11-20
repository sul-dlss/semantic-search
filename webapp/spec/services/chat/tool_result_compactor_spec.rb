# frozen_string_literal: true

require "rails_helper"

RSpec.describe Chat::ToolResultCompactor do
  subject(:compactor) { described_class.new }

  it "preserves ranked passage evidence while bounding long excerpts" do
    text = compactor.call(
      text: "unbounded",
      structured_content: {
        passages: [
          {
            rank: 1,
            text: "x" * 3_000,
            chunk_id: "chunk-1",
            chunk_index: 4,
            pages: [ 571 ],
            document_id: "vm857hw3603",
            document_title: "Stanford report. Volume 36, 2003-2004",
            url: "/catalog/vm857hw3603"
          }
        ]
      }
    )

    expect(text).to start_with("Passage evidence:\n1. Stanford report. Volume 36, 2003-2004")
    expect(text).to include("page 571", "Source: /catalog/vm857hw3603")
    expect(text).not_to include("chunk 4")
    expect(text.length).to be < 2_300
  end

  it "sends a whole indexer-sized chunk without cutting off its end" do
    ending = "Faculty members include Barton J. Bernstein, history; Henry S. Breitrose, communication."
    chunk = ("x" * (1_490 - ending.length)) + ending

    text = compactor.call(
      text: "Passages",
      structured_content: {
        passages: [ { rank: 1, text: chunk, filename: "fx254ps0743_04_0213.xml", chunk_index: 2,
                      document_id: "fx254ps0743", url: "/catalog/fx254ps0743" } ]
      }
    )

    expect(text).to include(ending)
  end

  it "joins neighbouring chunks of a file into one passage without repeating their overlap" do
    passage = lambda do |rank, index, text|
      { rank:, text:, filename: "fx254ps0743_04_0213.xml", chunk_index: index, pages: [ 213 ],
        document_id: "fx254ps0743", document_title: "Campus report. Volume 8, 1975-1976",
        url: "/catalog/fx254ps0743" }
    end
    text = compactor.call(
      text: "Passages",
      structured_content: {
        passages: [
          passage.call(1, 3, "Robert E. McGinn, values, technology,\nand society; Anne McMahon, sociology. " \
                             "Three undergraduates serve."),
          { rank: 2, text: "Unrelated evidence", chunk_id: "other", document_id: "other", url: "/catalog/other" },
          passage.call(3, 2, "Clebsch heads the American studies policy committee. Faculty members include " \
                             "Barton J. Bernstein, history; Robert E. McGinn, values, technology,\nand society; " \
                             "Anne McMahon, sociology.")
        ]
      }
    )

    expect(text).to include(
      "1, 3. Campus report. Volume 8, 1975-1976 (fx254ps0743_04_0213.xml, page 213)\n" \
      "Clebsch heads the American studies policy committee. Faculty members include Barton J. Bernstein, " \
      "history; Robert E. McGinn, values, technology,\nand society; Anne McMahon, sociology. Three undergraduates serve."
    )
    expect(text.scan("Anne McMahon").length).to eq(1)
    expect(text.index("Clebsch heads")).to be < text.index("Unrelated evidence")
  end

  it "keeps chunks that are not neighbours as separate passages" do
    text = compactor.call(
      text: "Passages",
      structured_content: {
        passages: [ 1, 3 ].map do |index|
          { rank: index, text: "Chunk #{index} evidence", filename: "frogs.xml", chunk_index: index,
            document_id: "frogs", url: "/catalog/frogs" }
        end
      }
    )

    expect(text).to include("1. frogs (frogs.xml)\nChunk 1 evidence", "3. frogs (frogs.xml)\nChunk 3 evidence")
  end

  it "sends a chunk once when passage and catalog search both return it" do
    text = compactor.call(
      text: "Combined discovery",
      structured_content: {
        passages: [
          {
            rank: 1,
            text: "The Red Barn was built between 1878 and 1880.",
            chunk_id: "vm857hw3603_vm857hw3603_04_0526_pdf_c6",
            filename: "vm857hw3603_04_0526.pdf",
            chunk_index: 6,
            document_id: "vm857hw3603",
            document_title: "Stanford report. Volume 36, 2003-2004",
            url: "/catalog/vm857hw3603"
          }
        ],
        results: [
          {
            id: "vm857hw3603",
            title: "Stanford report. Volume 36, 2003-2004",
            url: "/catalog/vm857hw3603",
            matched_chunks: [
              {
                text: "The Red Barn was built between 1878 and 1880.",
                filename: "vm857hw3603_04_0526.pdf",
                chunk_index: 6,
                pages: [ 526 ]
              }
            ]
          }
        ]
      }
    )

    expect(text.scan("The Red Barn was built between 1878 and 1880.").length).to eq(1)
    expect(text).to include("Passage evidence:", "Catalog evidence:")
  end

  it "keeps the best new chunk of a catalog result without hiding the rest" do
    result = lambda do |chunk_indexes|
      {
        text: "Catalog results",
        structured_content: {
          results: [
            {
              id: "vm857hw3603",
              title: "Stanford report. Volume 36, 2003-2004",
              url: "/catalog/vm857hw3603",
              matched_chunks: chunk_indexes.map do |index|
                { text: "Chunk #{index} evidence", filename: "vm857hw3603_04_0526.pdf", chunk_index: index }
              end
            }
          ]
        }
      }
    end

    first = compactor.call(result.call([ 1, 2, 3 ]))
    second = compactor.call(result.call([ 1, 2, 3 ]))

    expect(first).to include("Chunk 1 evidence")
    expect(first).not_to include("Chunk 2 evidence", "Chunk 3 evidence")
    expect(second).to include("Chunk 2 evidence")
    expect(second).not_to include("Chunk 1 evidence", "Chunk 3 evidence")
  end

  it "leaves evidence that does not fit this message for a later tool result" do
    stub_const("#{described_class}::MAX_CHARACTERS", 1_000)
    result = {
      text: "Passages",
      structured_content: {
        passages: (1..3).map do |index|
          { rank: index, text: "Passage #{index} " + ("y" * 380), chunk_id: "chunk-#{index}",
            document_id: "frogs", url: "/catalog/frogs" }
        end
      }
    }

    first = compactor.call(result)

    expect(first).to include("Passage 1", "Passage 2", "[Additional evidence omitted to keep the prompt bounded.]")
    expect(first).not_to include("Passage 3")
    expect(compactor.call(result)).to include("Passage 3")
  end

  it "stops emitting evidence once the conversation budget is spent" do
    compactor = described_class.new(character_budget: 600)
    passage = lambda do |index|
      {
        text: "Passages",
        structured_content: {
          passages: [
            { rank: 1, text: "y" * 400, chunk_id: "chunk-#{index}", document_id: "frogs", url: "/catalog/frogs" }
          ]
        }
      }
    end

    expect(compactor.call(passage.call(1))).to include("y" * 400)
    expect(compactor.call(passage.call(2))).to eq(
      "Evidence budget reached; answer using the evidence already returned."
    )
  end

  it "retains document pagination instructions when compacting chunks" do
    text = compactor.call(
      text: "Document chunks",
      structured_content: {
        document_id: "frogs",
        returned_chunks: 1,
        total_chunks: 20,
        complete: false,
        next_cursor: "next-page",
        chunks: [ { id: "chunk-1", text: "Evidence", chunk_index: 0 } ]
      }
    )

    expect(text).to include("Document frogs: 1 of 20 chunks", "Evidence", "Continue with cursor: next-page")
  end

  it "joins consecutive document chunks of a file" do
    text = compactor.call(
      text: "Document chunks",
      structured_content: {
        document_id: "frogs",
        returned_chunks: 3,
        total_chunks: 3,
        complete: true,
        chunks: [
          { id: "c0", text: "The frog list begins with Bullfrog, Leopard frog,", filename: "a.xml", chunk_index: 0 },
          { id: "c1", text: "Bullfrog, Leopard frog, and Tree frog.", filename: "a.xml", chunk_index: 1 },
          { id: "c2", text: "A new page.", filename: "b.xml", chunk_index: 0 }
        ]
      }
    )

    expect(text).to include("(a.xml)\nThe frog list begins with Bullfrog, Leopard frog, and Tree frog.", "(b.xml)\nA new page.")
  end
end
