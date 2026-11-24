# frozen_string_literal: true

# Solr's combined query handler is required for RRF queries. Other searches
# continue to use Blacklight's configured Solr request paths.
class CombinedQueryRepository < Blacklight::Solr::Repository
  HYBRID_PATH = "hybrid"

  # Parameters of a hybrid request that only the combined query handler understands, or that a
  # count-only request has no use for.
  HYBRID_ONLY_PARAMS = %w[combiner combiner.query combiner.algorithm sort start rows facet.field hl].freeze

  # Solr 10.1's combined query handler throws ArrayIndexOutOfBoundsException when it computes
  # facet.query counts over a knn-based vector query (field facets are fine). So a hybrid search
  # gets its facet.query counts from a second, count-only /select request matching the same
  # documents: those of either the lexical or the vector query.
  def send_and_receive(path, solr_params = {})
    # A SearchBuilder becomes its request hash. A Hash is used as is: HashWithIndifferentAccess#to_hash
    # would turn its keys into strings, and Blacklight then no longer finds params[:json].
    params = solr_params.is_a?(Hash) ? solr_params : solr_params.to_hash
    facet_queries = params.find { |key, _| key.to_s == "facet.query" }&.last
    return super if path != HYBRID_PATH || Array(facet_queries).empty?

    response = super(path, params.reject { |key, _| key.to_s == "facet.query" })
    counts = response.dig("facet_counts")
    counts["facet_queries"] = facet_query_counts(params) if counts
    response
  end

  private

  def facet_query_counts(params)
    json = params[:json]
    count_params = params.reject { |key, _| HYBRID_ONLY_PARAMS.include?(key.to_s) }
    count_params = count_params.merge(
      rows: 0,
      json: json.except(:queries).merge(query: { bool: { should: json[:queries].values } })
    )

    send_and_receive(blacklight_config.solr_path, count_params).dig("facet_counts", "facet_queries")
  end

  def default_search_path(solr_params)
    return HYBRID_PATH if solr_params[:json]&.dig(:queries).present?

    super
  end
end
