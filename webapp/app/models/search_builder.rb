# frozen_string_literal: true

class SearchBuilder < Blacklight::SearchBuilder
  include Blacklight::Solr::SearchBuilderBehavior

  # Solr normalizes cosine similarity scores to the range [0, 1]. The retrieval
  # evaluation baseline has relevant results down to 0.84, so this leaves some
  # recall headroom while excluding weak semantic matches.
  VECTOR_MIN_RETURN = 0.8
  VECTOR_BOOST = 100.0

  # How many parents the vector search considers, each by its best-matching chunk. The threshold
  # (VECTOR_MIN_RETURN) is then applied exactly to those parents' chunks. Without this cap Solr
  # scored every one of the ~2.6M chunks (~4-9 s per search). Against the uncapped query on the
  # chat evaluation questions, 1000 gave the same top 20, in the same order, for 24 of 25
  # unfiltered and 25 of 25 filtered searches; the misses were matches just above the threshold.
  # It also caps the number of vector results, and so the facet counts, at this many.
  VECTOR_CANDIDATE_PARENTS = 1000
  PARENT_FILTER = "doc_type_ssi:parent"

  # Lexical chunk matches are scored per chunk and rolled up to the parent with
  # score=max, so this is comparable with one strong chunk rather than with a
  # whole-document field within the lexical ranking.
  CHUNK_BOOST = 1.0

  # Minimum-match for the lexical half of a hybrid search. Without it edismax ORs the terms,
  # so a long natural-language query matches any document containing one of its words
  # (e.g. "California"), which inflates the result count and dilutes the lexical ranking
  # fed into RRF. Queries of one or two terms still require every term.
  HYBRID_LEXICAL_MM = "2<75%"

  self.default_processor_chain += [ :add_embedding_to_query ]

  attr_reader :query_embedding

  def add_embedding_to_query(solr_parameters)
    unless search_state.params[:q].present?
      # q.alt only applies to DisMax parsers. Keep the initial browse request
      # explicit so Solr returns documents and their facet counts.
      solr_parameters[:q] = "*:*" if solr_parameters[:q].blank?
      return
    end

    add_vector_candidates(solr_parameters) unless search_state.params[:search_type] == "keyword"

    if search_state.params[:search_type] == "hybrid"
      lexical_queries = keyword(solr_parameters, mm: HYBRID_LEXICAL_MM) + keyword_chunks(mm: HYBRID_LEXICAL_MM)
      # The named JSON queries specify their own parsers. A request-level q
      # interferes with their interpretation by Solr's combined handler.
      solr_parameters.delete(:q)
      solr_parameters[:json] = (solr_parameters[:json] || {}).except(:query).merge(queries: {
        lexical: { bool: { should: lexical_queries } },
        vector: vector_similarity.first
      })
      solr_parameters[:combiner] = true
      solr_parameters[:"combiner.query"] = %w[lexical vector]
      solr_parameters[:"combiner.algorithm"] = "rrf"
      return
    end

    if search_state.params[:search_type] == "vector"
      solr_parameters.delete(:q)
    else
      solr_parameters[:defType] = "edismax"
    end
    solr_parameters[:json] ||= { query: {} }
    # Exactly one of these is non-empty here: keyword mode has only the lexical clauses and vector
    # mode only the vector one. Vector mode needs no rerank pass: its ranking already is the
    # vector score, and reranking with the same vectorSimilarity query would make Solr run that
    # (expensive, unbounded) query a second time without changing the order.
    solr_parameters[:json][:query][:bool] = {
      should: keyword(solr_parameters) + keyword_chunks + vector_similarity
    }
  end

  def keyword(solr_parameters, mm: nil)
    return [] if search_state.params[:search_type] == "vector"

    must_queries = solr_parameters.dig(:json, :query, :bool, :must)
    return Array.wrap(must_queries) if must_queries.present? # advance search is enabled

    return [] unless solr_parameters[:q].present?

    [ { edismax: { query: solr_parameters[:q], mm: }.compact } ]
  end

  # Lexical search over the extracted chunk text. Mirrors #vector_similarity: the match is
  # made against child documents and rolled up to the parent with score=max, so
  # a phrase occurring in one chunk of a 1,000-chunk volume is not diluted by
  # document length.
  def keyword_chunks(mm: nil)
    return [] if search_state.params[:search_type] == "vector"
    return [] unless search_state.params[:q].present?

    [
      {
        boost: {
          b: CHUNK_BOOST,
          query: {
            parent: {
              which: "doc_type_ssi:parent",
              # Without this the parent parser defaults to score=none and every match scores 0.
              score: "max",
              query: {
                edismax: {
                  query: search_state.params[:q],
                  qf: "chunk_text_tesi",
                  mm:
                }.compact
              }
            }
          }
        }
      }
    ]
  end

  def vector_similarity
    return [] if search_state.params[:search_type] == "keyword"
    @vector_similarity ||= [
      {
        boost: {
          b: VECTOR_BOOST,
          query: {
            parent: {
              which: PARENT_FILTER,
              # Without this the parent parser defaults to score=none and every match scores 0.
              score: "max",
              # Apply the threshold to child chunks before rolling their best score up to the
              # parent, but only to the candidate chunks (see #add_vector_candidates). A
              # local-params string, so that $vector_candidates is dereferenced.
              query: "{!vectorSimilarity f=vector minReturn=#{VECTOR_MIN_RETURN} " \
                     "preFilter=$vector_candidates}#{embedding_vector}"
            }
          }
        }
      }
    ]
  end

  # Defines $vector_candidates: the best-matching chunk of each of the VECTOR_CANDIDATE_PARENTS
  # nearest parents. childrenOf makes knn count parents rather than chunks, so one document with
  # many similar chunks cannot use up the budget. The request's filters (facets) go in
  # parents.preFilter: a nested query does not inherit them, and applying them only afterwards
  # would discard candidates from other parents and leave too few that match.
  def add_vector_candidates(solr_parameters)
    knn = "{!knn f=vector topK=#{VECTOR_CANDIDATE_PARENTS} childrenOf=$vector_parents"
    solr_parameters[:vector_parents] = PARENT_FILTER

    # Each filter goes in its own parameter, so its local params and quoting are left intact.
    filters = Array(solr_parameters[:fq])
    filters.each_with_index { |filter, i| solr_parameters[:"vector_parent_filter_#{i}"] = filter }
    if filters.one?
      knn += " parents.preFilter=$vector_parent_filter_0"
    elsif filters.many?
      solr_parameters[:vector_parent_filter] =
        "{!bool #{filters.each_index.map { |i| "filter=$vector_parent_filter_#{i}" }.join(' ')}}"
      knn += " parents.preFilter=$vector_parent_filter"
    end

    solr_parameters[:vector_candidates] = "#{knn}}#{embedding_vector}"
  end

  def embedding_vector
    @embedding_vector ||= "[#{retrieve_embedding(search_state.params[:q]).join(', ')}]"
  end

  def retrieve_embedding(input)
    @query_embedding = GeminiEmbedding.query_embedding(input)
  end
end
