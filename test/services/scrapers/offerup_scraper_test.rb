require "test_helper"

# OfferupScraper needs a real headless browser to load OfferUp's React
# app, so these tests skip that part and call `parse_listings` directly
# with fixture JSON shaped like OfferUp's own `__NEXT_DATA__` listing
# objects -- exercising the parsing/filtering logic with no browser
# involved.
class Scrapers::OfferupScraperTest < ActiveSupport::TestCase
  SEARCH = { product_name: "Chevy Spark (2015+, automatic)", make: "Chevrolet" }.freeze

  RAW_ITEMS = [
    {
      "title" => "2019 Chevrolet Spark LS Clean Title 28,000 mi Automatic",
      "price" => "6200",
      "listingId" => "abc123",
      "conditionText" => "Used",
      "locationName" => "Phoenix, AZ"
    },
    {
      # Wrong make entirely -- should be filtered out by ListingFilter.
      "title" => "2019 Toyota Corolla Clean Title Automatic",
      "price" => "6000",
      "listingId" => "def456",
      "conditionText" => "Used",
      "locationName" => "Phoenix, AZ"
    },
    {
      # No price at all -- not a usable listing.
      "title" => "2019 Chevrolet Spark",
      "price" => "0",
      "listingId" => "ghi789"
    }
  ].freeze

  test "parses a matching item into a listing hash" do
    found = Scrapers::OfferupScraper.parse_listings(RAW_ITEMS, SEARCH)
    listing = found.find { |l| l[:listing_id] == "abc123" }

    assert listing.present?
    assert_equal "offerup", listing[:source]
    assert_equal 6_200.0, listing[:price_usd]
    assert_equal "https://offerup.com/item/detail/abc123", listing[:url]
    assert_equal "Chevrolet", listing[:make]
    assert_equal 28_000, listing[:mileage]
  end

  test "rejects a listing whose make does not match the search" do
    found = Scrapers::OfferupScraper.parse_listings(RAW_ITEMS, SEARCH)
    assert_nil found.find { |l| l[:listing_id] == "def456" }
  end

  test "rejects a listing with no usable price" do
    found = Scrapers::OfferupScraper.parse_listings(RAW_ITEMS, SEARCH)
    assert_nil found.find { |l| l[:listing_id] == "ghi789" }
  end
end
