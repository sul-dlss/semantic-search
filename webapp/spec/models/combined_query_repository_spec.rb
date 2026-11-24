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

RSpec.describe CombinedQueryRepository, "#search" do
  subject(:repository) { CatalogController.blacklight_config.repository }

  before { allow(repository).to receive(:send_and_receive) }

  it "asks Solr to search segments in parallel" do
    repository.search(params: { q: "x" })

    expect(repository).to have_received(:send_and_receive).with("select", hash_including(multiThreaded: true, q: "x"))
  end

  it "lets the caller turn it off" do
    repository.search(params: { q: "x", multiThreaded: false })

    expect(repository).to have_received(:send_and_receive).with("select", hash_including(multiThreaded: false))
  end
end
