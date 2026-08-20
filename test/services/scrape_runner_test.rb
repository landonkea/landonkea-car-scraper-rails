require "test_helper"

# ScrapeRunner ties every scraper together -- these tests stub out the
# four scraper classes' `.scrape` methods (so no real network/browser
# activity happens) and check that saving, deduping, scoring, and
# alerting behave the way main.py's `_run_one_search` did.
class ScrapeRunnerTest < ActiveSupport::TestCase
  SEARCH = { product_name: "Honda Fit (2015+, automatic)", make: "Honda" }.freeze

  def stub_scrapers(craigslist: [], offerup: [], ebay: [], cargurus: [], &block)
    Scrapers::CraigslistScraper.stub(:scrape, ->(_search) { craigslist }) do
      Scrapers::OfferupScraper.stub(:scrape, ->(_search) { offerup }) do
        Scrapers::EbayScraper.stub(:scrape, ->(_search) { ebay }) do
          Scrapers::CargurusScraper.stub(:scrape, ->(_search) { cargurus }) do
            block.call
          end
        end
      end
    end
  end

  test "run_search saves new listings found by any scraper" do
    scraped = [
      { source: "craigslist", listing_id: "cl-1", title: "2019 Honda Fit", price_usd: 5_500, url: "https://x.test/1", condition: nil, location: "Tempe", year: 2019, make: "Honda", model: "Fit", mileage: 40_000, transmission: "Automatic", doors: 4, title_status: "Clean", fuel_type: "Gas", seller_type: "private_party" }
    ]

    stub_request(:post, /discord.com\/api\/webhooks/).to_return(status: 204)

    result = stub_scrapers(craigslist: scraped) { ScrapeRunner.run_search(SEARCH) }

    assert_equal 1, result[:saved]
    assert_equal 1, result[:new]
    assert Listing.exists?(source: "craigslist", listing_id: "cl-1")
  end

  test "run_search updates an existing listing instead of creating a duplicate" do
    existing = Listing.create!(
      source: "craigslist", listing_id: "cl-2", title: "2018 Honda Fit", price_usd: 6_500,
      url: "https://x.test/2", first_seen_at: 2.days.ago, last_seen_at: 2.days.ago, is_active: false
    )

    scraped = [
      { source: "craigslist", listing_id: "cl-2", title: "2018 Honda Fit LX", price_usd: 6_000, url: "https://x.test/2", condition: nil, location: nil, year: 2018, make: "Honda", model: "Fit", mileage: 50_000, transmission: "Automatic", doors: 4, title_status: "Clean", fuel_type: "Gas", seller_type: nil }
    ]

    stub_request(:post, /discord.com\/api\/webhooks/).to_return(status: 204)

    result = stub_scrapers(craigslist: scraped) { ScrapeRunner.run_search(SEARCH) }

    assert_equal 0, result[:new]
    existing.reload
    assert_equal 6_000, existing.price_usd
    assert existing.is_active?
  end

  test "run_search does not send a Discord alert when nothing new or great was found" do
    existing = Listing.create!(
      source: "craigslist", listing_id: "cl-3", title: "2018 Honda Fit", price_usd: 9_000,
      url: "https://x.test/3", first_seen_at: 2.days.ago, last_seen_at: 2.days.ago
    )
    scraped = [
      { source: "craigslist", listing_id: "cl-3", title: "2018 Honda Fit", price_usd: 9_000, url: "https://x.test/3", condition: nil, location: nil, year: 2018, make: "Honda", model: "Fit", mileage: 140_000, transmission: "Automatic", doors: 4, title_status: "Clean", fuel_type: "Gas", seller_type: nil }
    ]

    result = stub_scrapers(craigslist: scraped) { ScrapeRunner.run_search(SEARCH) }

    assert_not result[:alert_sent]
    assert_not_requested :post, /discord.com\/api\/webhooks/
  end

  test "expire_stale_listings marks listings not seen in 72+ hours inactive" do
    stale = Listing.create!(
      source: "craigslist", listing_id: "cl-4", title: "Old listing", price_usd: 5_000,
      url: "https://x.test/4", first_seen_at: 5.days.ago, last_seen_at: 4.days.ago, is_active: true
    )
    fresh = Listing.create!(
      source: "craigslist", listing_id: "cl-5", title: "Fresh listing", price_usd: 5_000,
      url: "https://x.test/5", first_seen_at: 1.hour.ago, last_seen_at: 1.hour.ago, is_active: true
    )

    ScrapeRunner.expire_stale_listings

    assert_not stale.reload.is_active?
    assert fresh.reload.is_active?
  end

  test "prune_old_inactive_listings deletes listings inactive for 180+ days" do
    old = Listing.create!(
      source: "craigslist", listing_id: "cl-6", title: "Ancient listing", price_usd: 5_000,
      url: "https://x.test/6", first_seen_at: 200.days.ago, last_seen_at: 200.days.ago, is_active: false
    )
    recent = Listing.create!(
      source: "craigslist", listing_id: "cl-7", title: "Recently sold", price_usd: 5_000,
      url: "https://x.test/7", first_seen_at: 5.days.ago, last_seen_at: 5.days.ago, is_active: false
    )

    ScrapeRunner.prune_old_inactive_listings

    assert_not Listing.exists?(old.id)
    assert Listing.exists?(recent.id)
  end
end
