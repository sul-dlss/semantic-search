# frozen_string_literal: true

# Solr's combined query handler is required for RRF queries. Other searches
# continue to use Blacklight's configured Solr request paths.
class CombinedQueryRepository < Blacklight::Solr::Repository
  HYBRID_PATH = "hybrid"

  # Searches each index segment on its own thread (Solr 9.7+) instead of one after another. The
  # vector queries are dominated by per-segment HNSW and exact-scan work, so this cuts their
  # latency roughly by the number of segments, up to the core count, without changing results.
  # Solr ignores the parameter on versions that do not support it.
  DEFAULT_PARAMS = { multiThreaded: true }.freeze

  # Defaults go in as kwargs, which Blacklight reverse-merges, so a caller's own value wins.
  def search(pos_params = nil, path: nil, params: nil, **kwargs)
    super(pos_params, path:, params:, **DEFAULT_PARAMS, **kwargs)
  end

  private

  def default_search_path(solr_params)
    return HYBRID_PATH if solr_params[:json]&.dig(:queries).present?

    super
  end
end
