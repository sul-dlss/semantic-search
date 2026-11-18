# frozen_string_literal: true

require "rails_helper"

RSpec.describe "solr request instrumentation" do
  def instrument(qtime:, error: nil)
    ActiveSupport::Notifications.instrument("solr_request.blacklight", path: "select") do |payload|
      raise error if error

      payload[:response] = { "responseHeader" => { "QTime" => qtime } }
    end
  end

  it "records the first request in the request cycle for the results page" do
    instrument(qtime: 812)
    instrument(qtime: 4)

    expect(Current.solr_request).to include(qtime_ms: 812, duration_ms: a_kind_of(Float))
  end

  it "logs each request" do
    allow(Rails.logger).to receive(:info)

    instrument(qtime: 12)

    expect(Rails.logger).to have_received(:info) do |message|
      expect(JSON.parse(message)).to include("event" => "solr_request.blacklight", "outcome" => "success",
                                             "path" => "select", "qtime_ms" => 12)
    end
  end

  it "logs a failed request without recording it" do
    allow(Rails.logger).to receive(:warn)

    expect { instrument(qtime: 1, error: RuntimeError) }.to raise_error(RuntimeError)

    expect(Current.solr_request).to be_nil
    expect(Rails.logger).to have_received(:warn) do |message|
      expect(JSON.parse(message)).to include("outcome" => "error", "error_class" => "RuntimeError")
    end
  end
end
