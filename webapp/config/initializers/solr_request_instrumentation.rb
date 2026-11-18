# frozen_string_literal: true

ActiveSupport::Notifications.subscribe("solr_request.blacklight") do |event|
  error_class = event.payload[:exception]&.first
  qtime_ms = event.payload[:response]&.dig("responseHeader", "QTime")
  # The results page reports the first request, which is the catalog search itself.
  Current.solr_request ||= { duration_ms: event.duration, qtime_ms: qtime_ms } unless error_class

  level = error_class ? :warn : :info
  Rails.logger.public_send(
    level,
    {
      event: event.name,
      outcome: error_class ? "error" : "success",
      path: event.payload[:path],
      duration_ms: event.duration.round(1),
      qtime_ms: qtime_ms,
      error_class: error_class
    }.compact.to_json
  )
end
