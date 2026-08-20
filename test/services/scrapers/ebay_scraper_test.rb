require "test_helper"

# EbayScraper needs a real headless browser to fetch eBay's rendered
# HTML, so these tests skip that part entirely and call
# `parse_listings` directly with a fixture HTML string -- exercising
# the actual parsing/filtering logic without needing Ferrum or a
# network connection.
class Scrapers::EbayScraperTest < ActiveSupport::TestCase
  SEARCH = { product_name: "Kia Rio (2015+, automatic)", make: "Kia" }.freeze

  SAMPLE_HTML = <<~HTML
    <html><body>
      <ul>
        <li class="s-card">
          <div class="s-card__title">2018 Kia Rio LX Clean Title 38,000 mi Automatic</div>
          <a class="s-card__link" href="https://www.ebay.com/itm/1122334455">link</a>
          <div class="s-card__price">$5,900.00</div>
          <div class="s-card__subtitle">Used</div>
        </li>
        <li class="s-card">
          <div class="s-card__title">2018 Kia Rio, 3 bids so far</div>
          <a class="s-card__link" href="https://www.ebay.com/itm/9988776655">link</a>
          <div class="s-card__price">$3,200.00</div>
        </li>
        <li class="s-card">
          <div class="s-card__title">Shop on eBay</div>
          <a class="s-card__link" href="https://www.ebay.com/itm/0000000000">link</a>
          <div class="s-card__price">$1.00</div>
        </li>
      </ul>
    </body></html>
  HTML

  test "parses a matching card into a listing hash" do
    found = Scrapers::EbayScraper.parse_listings(SAMPLE_HTML, SEARCH)
    listing = found.find { |l| l[:listing_id] == "1122334455" }

    assert listing.present?
    assert_equal "ebay", listing[:source]
    assert_equal 5_900.0, listing[:price_usd]
    assert_equal 2018, listing[:year]
    assert_equal "Kia", listing[:make]
    assert_equal 38_000, listing[:mileage]
  end

  test "rejects auction listings with active bids" do
    found = Scrapers::EbayScraper.parse_listings(SAMPLE_HTML, SEARCH)
    assert_nil found.find { |l| l[:listing_id] == "9988776655" }
  end

  test "rejects the 'Shop on eBay' placeholder card" do
    found = Scrapers::EbayScraper.parse_listings(SAMPLE_HTML, SEARCH)
    assert_nil found.find { |l| l[:listing_id] == "0000000000" }
  end

  test "clean_title strips eBay's screen-reader artifacts" do
    assert_equal "2018 Kia Rio LX", Scrapers::EbayScraper.clean_title("2018 Kia Rio LXopens in a new window")
  end
end
