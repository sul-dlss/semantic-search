require "rails_helper"

RSpec.describe CombinedQueryRepository do
  subject(:repository) { described_class.allocate }

  before do
    allow(repository).to receive(:blacklight_config).and_return(CatalogController.blacklight_config)
  end

  it "uses the combined query handler for RRF requests" do
    expect(repository.send(:default_search_path, { json: { queries: { lexical: {}, vector: {} } } })).to eq("hybrid")
  end

  it "keeps ordinary JSON queries on Blacklight's JSON path" do
    expect(repository.send(:default_search_path, { json: { query: { knn: {} } } })).to eq("select")
  end
end

RSpec.describe CombinedQueryRepository, "#send_and_receive" do
  subject(:repository) { CatalogController.blacklight_config.repository }

  let(:hybrid_params) do
    {
      rows: 20,
      sort: "score desc",
      facet: true,
      "facet.field": [ "format_hsim" ],
      "facet.query": [ "child_count_i:1", "child_count_i:[2 TO *]" ],
      fq: [ "{!term f=format_hsim}Text" ],
      combiner: true,
      "combiner.query": %w[lexical vector],
      "combiner.algorithm": "rrf",
      vector_candidates: "{!knn f=vector topK=1000}[0.1]",
      json: { queries: { lexical: { edismax: { query: "coasts" } }, vector: { knn: { f: "vector" } } } }
    }
  end
  let(:requests) { [] }

  before do
    allow(repository.connection).to receive(:send_and_receive) do |path, request|
      body = JSON.parse(request[:data])
      requests << [ path, body ]
      if path == "hybrid"
        { "response" => { "numFound" => 2, "docs" => [] },
          "facet_counts" => { "facet_queries" => {}, "facet_fields" => { "format_hsim" => [ "Text", 2 ] } } }
      else
        { "response" => { "numFound" => 2, "docs" => [] },
          "facet_counts" => { "facet_queries" => { "child_count_i:1" => 1, "child_count_i:[2 TO *]" => 1 } } }
      end
    end
  end

  it "leaves facet.query out of the hybrid request, which Solr cannot facet with knn" do
    repository.send_and_receive("hybrid", hybrid_params)

    hybrid = requests.find { |path, _| path == "hybrid" }.last
    expect(hybrid["params"]).not_to have_key("facet.query")
    expect(hybrid["params"]["facet.field"]).to eq([ "format_hsim" ])
  end

  it "counts the facet queries with /select over the documents matching either query" do
    repository.send_and_receive("hybrid", hybrid_params)

    path, counts = requests.find { |p, _| p == "select" }
    expect(path).to eq("select")
    expect(counts["query"]).to eq("bool" => { "should" => [ { "edismax" => { "query" => "coasts" } },
                                                            { "knn" => { "f" => "vector" } } ] })
    expect(counts["params"]).to include("rows" => 0, "facet.query" => [ "child_count_i:1", "child_count_i:[2 TO *]" ],
                                        "fq" => [ "{!term f=format_hsim}Text" ],
                                        "vector_candidates" => "{!knn f=vector topK=1000}[0.1]")
    expect(counts["params"].keys).not_to include("combiner", "combiner.query", "sort", "facet.field")
  end

  it "returns the hybrid response with the separately counted facet queries" do
    response = repository.send_and_receive("hybrid", hybrid_params)

    expect(response.dig("facet_counts", "facet_queries")).to eq("child_count_i:1" => 1, "child_count_i:[2 TO *]" => 1)
    expect(response.dig("facet_counts", "facet_fields", "format_hsim")).to eq([ "Text", 2 ])
  end

  it "keeps sending JSON when given a HashWithIndifferentAccess, as SearchBuilder#to_hash returns" do
    response = repository.send_and_receive("hybrid", hybrid_params.with_indifferent_access)

    expect(requests.map(&:first)).to eq(%w[hybrid select])
    expect(requests.first.last["queries"]).to include("lexical", "vector")
    expect(response.dig("facet_counts", "facet_queries")).to eq("child_count_i:1" => 1, "child_count_i:[2 TO *]" => 1)
  end

  it "sends other requests unchanged" do
    repository.send_and_receive("select", hybrid_params.except(:json).merge(json: { query: { knn: {} } }))

    expect(requests.map(&:first)).to eq([ "select" ])
    expect(requests.first.last["params"]["facet.query"]).to eq([ "child_count_i:1", "child_count_i:[2 TO *]" ])
  end
end
