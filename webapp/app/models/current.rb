# frozen_string_literal: true

# Request-scoped state, reset by Rails between requests.
class Current < ActiveSupport::CurrentAttributes
  # The first query embedding looked up in this request: { duration_ms: Float, cached: boolean }.
  # Set by config/initializers/query_embedding_instrumentation.rb.
  attribute :embedding_lookup

  # The first Solr request made in this request: { duration_ms: Float, qtime_ms: Integer or nil }.
  # duration_ms is the round trip as seen by Rails; qtime_ms is Solr's own reported query time.
  # Set by config/initializers/solr_request_instrumentation.rb.
  attribute :solr_request
end
