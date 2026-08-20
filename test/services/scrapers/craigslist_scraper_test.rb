require "test_helper"

# These tests stub out Craigslist's HTML response with WebMock so we can
# check the scraper's parsing/filtering logic without making a real
# network request. The fixture HTML below is a trimmed-down but
# structurally accurate stand-in for what craigslist.org actually
# returns for a cars+trucks search.
class Scrapers::CraigslistScraperTest < ActiveSupport::TestCase
  SEARCH = { product_name: "Honda Fit (2015+, automatic)", make: "Honda" }.freeze

  SAMPLE_HTML = <<~HTML
    <html><body>
      <ul>
        <li class="cl-static-search-result">
          <a href="https://phoenix.craigslist.org/cto/good-fit.html">
            <div class="title">2019 Honda Fit LX Clean Title 45,000 mi Automatic</div>
            <div class="price">$5500</div>
            <div class="location">Tempe</div>
          </a>
        </li>
        <li class="cl-static-search-result">
          <a href="https://phoenix.craigslist.org/cto/salvage-fit.html">
            <div class="title">2019 Honda Fit salvage title, needs work</div>
            <div class="price">$2500</div>
            <div class="location">Mesa</div>
          </a>
        </li>
        <li class="cl-static-search-result">
          <a href="/cto/relative-fit.html">
            <div class="title">2020 Honda Fit Sport Clean Title Automatic</div>
            <div class="price">$6200</div>
          </a>
        </li>
      </ul>
    </body></html>
  HTML

  setup do
    Scrapers::CraigslistScraper::REGIONS.each do |region|
      stub_request(:get, /www\.craigslist\.org\/search\/area\/#{region}/)
        .to_return(status: 200, body: SAMPLE_HTML, headers: { "Content-Type" => "text/html" })
    end
  end

  test "returns a listing hash with the right fields for a matching card" do
    found = Scrapers::CraigslistScraper.scrape(SEARCH)
    listing = found.find { |l| l[:listing_id] == "craigslist-good-fit.html" }

    assert listing.present?
    assert_equal "craigslist", listing[:source]
    assert_equal 5500.0, listing[:price_usd]
    assert_equal "Tempe", listing[:location]
    assert_equal 2019, listing[:year]
    assert_equal "Honda", listing[:make]
    assert_equal 45_000, listing[:mileage]
    assert_equal "Clean", listing[:title_status]
  end

  test "rejects a salvage-title listing" do
    found = Scrapers::CraigslistScraper.scrape(SEARCH)
    assert_nil found.find { |l| l[:listing_id] == "craigslist-salvage-fit.html" }
  end

  test "derives the listing_id from the last URL segment even for a relative href" do
    # Craigslist's search-result links are normally already absolute, so
    # (matching Python's craigslist.py) this scraper doesn't bother
    # rewriting a relative href -- it just uses whatever the page gave it.
    found = Scrapers::CraigslistScraper.scrape(SEARCH)
    listing = found.find { |l| l[:listing_id] == "craigslist-relative-fit.html" }

    assert listing.present?
    assert_equal "/cto/relative-fit.html", listing[:url]
  end

  test "does not duplicate listings seen in more than one region" do
    found = Scrapers::CraigslistScraper.scrape(SEARCH)
    ids = found.map { |l| l[:listing_id] }
    assert_equal ids.uniq.length, ids.length
  end

  test "does not blow up when a region's request fails" do
    Scrapers::CraigslistScraper::REGIONS.each do |region|
      stub_request(:get, /www\.craigslist\.org\/search\/area\/#{region}/).to_timeout
    end

    assert_nothing_raised { Scrapers::CraigslistScraper.scrape(SEARCH) }
  end
end
