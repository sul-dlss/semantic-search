require "rails_helper"

RSpec.describe SearchBuilder do
  subject(:builder) { described_class.allocate }

  before do
    allow(builder).to receive(:search_state)
      .and_return(instance_double(Blacklight::SearchState, params: { q: "first Marlins pitch", search_type: "vector" }))
    allow(builder).to receive(:retrieve_embedding).with("first Marlins pitch").and_return([ 0.1, 0.2 ])
  end

  describe "#vector_similarity" do
    it "applies the similarity threshold to the knn candidate chunks only" do
      vector_query = builder.vector_similarity.dig(0, :boost, :query, :parent, :query)

      expect(vector_query).to eq(
        "{!vectorSimilarity f=vector minReturn=#{described_class::VECTOR_MIN_RETURN} " \
        "preFilter=$vector_candidates}[0.1, 0.2]"
      )
    end
  end

  describe "#add_vector_candidates" do
    it "takes the best chunk of each of the nearest parents" do
      solr_parameters = {}

      builder.add_vector_candidates(solr_parameters)

      expect(solr_parameters).to eq(
        vector_parents: "doc_type_ssi:parent",
        vector_candidates: "{!knn f=vector topK=#{described_class::VECTOR_CANDIDATE_PARENTS} " \
                           "childrenOf=$vector_parents}[0.1, 0.2]"
      )
    end

    it "applies a facet filter to the parents before choosing candidates" do
      solr_parameters = { fq: [ "{!term f=collection_title_ss}Stanford Daily" ] }

      builder.add_vector_candidates(solr_parameters)

      expect(solr_parameters[:vector_parent_filter_0]).to eq("{!term f=collection_title_ss}Stanford Daily")
      expect(solr_parameters[:vector_candidates]).to include("parents.preFilter=$vector_parent_filter_0}")
      expect(solr_parameters).not_to have_key(:vector_parent_filter)
    end

    it "requires every filter when there are several" do
      solr_parameters = { fq: [ "{!term f=format_hsim}Text", "child_count_i:[2 TO *]" ] }

      builder.add_vector_candidates(solr_parameters)

      expect(solr_parameters).to include(
        vector_parent_filter_0: "{!term f=format_hsim}Text",
        vector_parent_filter_1: "child_count_i:[2 TO *]",
        vector_parent_filter: "{!bool filter=$vector_parent_filter_0 filter=$vector_parent_filter_1}"
      )
      expect(solr_parameters[:vector_candidates]).to include("parents.preFilter=$vector_parent_filter}")
    end
  end

  describe "#add_embedding_to_query" do
    it "uses a match-all query for the starting page so facets are populated" do
      allow(builder).to receive(:search_state)
        .and_return(instance_double(Blacklight::SearchState, params: {}))
      solr_parameters = { "q.alt": "*:*" }

      builder.add_embedding_to_query(solr_parameters)

      expect(solr_parameters[:q]).to eq("*:*")
      expect(solr_parameters).not_to have_key(:defType)
    end

    it "uses the threshold query for retrieval without a redundant vector rerank" do
      solr_parameters = { q: "first Marlins pitch" }

      builder.add_embedding_to_query(solr_parameters)

      vector_clause = builder.vector_similarity
      expect(solr_parameters.dig(:json, :query, :bool, :should)).to eq(vector_clause)
      expect(solr_parameters[:vector_candidates]).to start_with("{!knn ")
      expect(solr_parameters).not_to have_key(:q)
      expect(solr_parameters).not_to have_key(:defType)
      expect(solr_parameters[:json]).not_to have_key(:params)
      expect(solr_parameters).not_to include(:rq, :rqq, :rqq_vector)
    end

    it "uses edismax without reranking for keyword searches" do
      allow(builder).to receive(:search_state)
        .and_return(instance_double(Blacklight::SearchState, params: { q: "first Marlins pitch", search_type: "keyword" }))
      solr_parameters = { q: "first Marlins pitch" }

      builder.add_embedding_to_query(solr_parameters)

      expect(solr_parameters[:defType]).to eq("edismax")
      expect(solr_parameters[:q]).to eq("first Marlins pitch")
      expect(solr_parameters).not_to have_key(:vector_candidates)
      expect(solr_parameters).not_to include(:rq, :rqq, :rqq_vector)
    end

    it "sends hybrid searches as separate lexical and vector rankings for RRF" do
      allow(builder).to receive(:search_state)
        .and_return(instance_double(Blacklight::SearchState, params: { q: "first Marlins pitch", search_type: "hybrid" }))
      solr_parameters = { q: "first Marlins pitch" }

      builder.add_embedding_to_query(solr_parameters)

      expect(solr_parameters.dig(:json, :queries, :lexical, :bool, :should)).to eq(
        [ { edismax: { query: "first Marlins pitch", mm: "2<75%" } } ] + builder.keyword_chunks(mm: "2<75%")
      )
      expect(solr_parameters.dig(:json, :queries, :lexical, :bool, :should, 1, :boost, :query, :parent, :query, :edismax))
        .to include(mm: "2<75%")
      expect(solr_parameters.dig(:json, :queries, :vector)).to eq(builder.vector_similarity.first)
      expect(solr_parameters[:vector_candidates]).to start_with("{!knn ")
      expect(solr_parameters).to include(combiner: true, "combiner.query": %w[lexical vector],
                                         "combiner.algorithm": "rrf")
      expect(solr_parameters.dig(:json, :query)).to be_nil
      expect(solr_parameters).not_to include(:rq, :rqq, :rqq_vector)
      expect(solr_parameters).not_to have_key(:q)
      expect(solr_parameters).not_to have_key(:defType)
    end
  end
end
