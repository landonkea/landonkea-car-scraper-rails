require "test_helper"

# PriceAnalyzer is a port of Python's PriceAnalyzer class -- these tests
# build small in-memory batches of Listing records (saved, so scores can
# be persisted back to them) and check the resulting deal_score/
# is_great_deal against hand-worked-out expected values.
class PriceAnalyzerTest < ActiveSupport::TestCase
  test "a single listing with no group to compare against gets the baseline score" do
    listing = Listing.create!(
      source: "craigslist", listing_id: "solo-1", title: "2019 Honda Fit",
      price_usd: 5_000, url: "https://example.com/1",
      first_seen_at: Time.current, last_seen_at: Time.current
    )

    PriceAnalyzer.call([ listing ])
    listing.reload

    # price 5000 <= GREAT_DEAL_PRICE_USD (6000) -> baseline 90.0
    assert_in_delta 90.0, listing.deal_score, 0.01
  end

  test "a listing priced below the group median scores higher than one priced above it" do
    cheap = Listing.create!(
      source: "craigslist", listing_id: "cheap-1", title: "2019 Honda Fit",
      price_usd: 4_000, url: "https://example.com/cheap",
      first_seen_at: Time.current, last_seen_at: Time.current
    )
    pricey = Listing.create!(
      source: "craigslist", listing_id: "pricey-1", title: "2019 Honda Fit",
      price_usd: 8_000, url: "https://example.com/pricey",
      first_seen_at: Time.current, last_seen_at: Time.current
    )
    middle = Listing.create!(
      source: "craigslist", listing_id: "middle-1", title: "2019 Honda Fit",
      price_usd: 6_000, url: "https://example.com/middle",
      first_seen_at: Time.current, last_seen_at: Time.current
    )

    sorted = PriceAnalyzer.call([ cheap, pricey, middle ])

    assert_equal cheap, sorted.first
    assert_equal pricey, sorted.last
    assert cheap.reload.deal_score > pricey.reload.deal_score
  end

  test "source reliability nudges otherwise-identical listings apart" do
    cargurus_listing = Listing.create!(
      source: "cargurus", listing_id: "cg-1", title: "2019 Honda Fit",
      price_usd: 6_000, url: "https://example.com/cg",
      first_seen_at: Time.current, last_seen_at: Time.current
    )
    craigslist_listing = Listing.create!(
      source: "craigslist", listing_id: "cl-1", title: "2019 Honda Fit",
      price_usd: 6_000, url: "https://example.com/cl",
      first_seen_at: Time.current, last_seen_at: Time.current
    )

    PriceAnalyzer.call([ cargurus_listing, craigslist_listing ])

    # CarGurus gets +1, Craigslist gets -3 -- a 4 point gap between two
    # otherwise-identical listings.
    assert_in_delta 4.0, cargurus_listing.reload.deal_score - craigslist_listing.reload.deal_score, 0.01
  end

  test "a listing far under median priced with suspicious condition text is capped and never a great deal" do
    normal_one = Listing.create!(
      source: "craigslist", listing_id: "normal-1", title: "2019 Honda Fit",
      price_usd: 6_000, url: "https://example.com/normal1",
      first_seen_at: Time.current, last_seen_at: Time.current
    )
    normal_two = Listing.create!(
      source: "craigslist", listing_id: "normal-2", title: "2019 Honda Fit",
      price_usd: 6_200, url: "https://example.com/normal2",
      first_seen_at: Time.current, last_seen_at: Time.current
    )
    suspicious = Listing.create!(
      source: "craigslist", listing_id: "suspicious-1", title: "2019 Honda Fit",
      price_usd: 1_000, condition: "Brand new, never driven",
      url: "https://example.com/suspicious",
      first_seen_at: Time.current, last_seen_at: Time.current
    )

    PriceAnalyzer.call([ normal_one, normal_two, suspicious ])
    suspicious.reload

    assert suspicious.deal_score <= 10.0
    assert_not suspicious.is_great_deal?
  end

  test "spec bonuses (clean title, low mileage, reliable make) push a listing's score up" do
    plain = Listing.create!(
      source: "craigslist", listing_id: "plain-1", title: "2016 Ram 1500",
      price_usd: 6_000, url: "https://example.com/plain",
      first_seen_at: Time.current, last_seen_at: Time.current
    )
    loaded = Listing.create!(
      source: "craigslist", listing_id: "loaded-1", title: "2021 Honda Fit",
      price_usd: 6_000, url: "https://example.com/loaded",
      title_status: "Clean", mileage: 30_000, year: 2021, make: "Honda", fuel_type: "Hybrid",
      first_seen_at: Time.current, last_seen_at: Time.current
    )

    PriceAnalyzer.call([ plain, loaded ])

    assert loaded.reload.deal_score > plain.reload.deal_score
  end

  test "stats reflects the price range and median of the batch it was given" do
    a = Listing.create!(source: "craigslist", listing_id: "s-1", title: "car", price_usd: 4_000, url: "https://example.com/a", first_seen_at: Time.current, last_seen_at: Time.current)
    b = Listing.create!(source: "craigslist", listing_id: "s-2", title: "car", price_usd: 6_000, url: "https://example.com/b", first_seen_at: Time.current, last_seen_at: Time.current)
    c = Listing.create!(source: "craigslist", listing_id: "s-3", title: "car", price_usd: 8_000, url: "https://example.com/c", first_seen_at: Time.current, last_seen_at: Time.current)

    analyzer = PriceAnalyzer.new([ a, b, c ])
    analyzer.call

    assert_equal 3, analyzer.stats[:count]
    assert_equal 4_000, analyzer.stats[:min]
    assert_equal 8_000, analyzer.stats[:max]
    assert_equal 6_000, analyzer.stats[:median]
  end
end
