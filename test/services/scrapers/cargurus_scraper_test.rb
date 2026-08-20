require "test_helper"

# CargurusScraper needs a real headless browser to hit CarGurus's
# internal search API, so these tests skip that part and call
# `parse_listings` directly with fixture JSON shaped like CarGurus's own
# API response items -- exercising the parsing/filtering/merging logic
# with no browser involved.
class Scrapers::CargurusScraperTest < ActiveSupport::TestCase
  SEARCH = { product_name: "Nissan Versa (2015+, automatic)", make: "Nissan" }.freeze

  RAW_ITEMS = [
    {
      "listingTitle" => "2018 Nissan Versa SV",
      "price" => 6_400,
      "id" => "998877",
      "carYear" => 2018,
      "makeName" => "Nissan",
      "modelName" => "Versa",
      "unitMileage" => { "value" => 41000 },
      "localizedTransmission" => "Automatic",
      "sellerCity" => "Chandler",
      "sellerRegion" => "AZ",
      "sellerType" => "DEALER"
    },
    {
      # No id -- can't build a URL or dedupe key, should be skipped.
      "listingTitle" => "2018 Nissan Versa S",
      "price" => 6_000,
      "id" => nil
    }
  ].freeze

  test "parses a matching item, preferring CarGurus's structured data when the title has no mileage" do
    found = Scrapers::CargurusScraper.parse_listings(RAW_ITEMS, SEARCH)
    listing = found.find { |l| l[:listing_id] == "cargurus-998877" }

    assert listing.present?
    assert_equal "cargurus", listing[:source]
    assert_equal 6_400.0, listing[:price_usd]
    assert_equal "https://www.cargurus.com/Cars/details/998877", listing[:url]
    # The title itself has no mileage number in it -- this only comes
    # through because parse_item falls back to CarGurus's own
    # `unitMileage` field when TitleParser found nothing in the title.
    assert_equal 41_000, listing[:mileage]
    assert_equal "Automatic", listing[:transmission]
    assert_equal "dealer", listing[:seller_type]
    assert_equal "Chandler, AZ", listing[:location]
  end

  test "skips an item with no id" do
    found = Scrapers::CargurusScraper.parse_listings(RAW_ITEMS, SEARCH)
    assert_equal 1, found.length
  end

  test "normalize_transmission treats CVT as automatic" do
    assert_equal "Automatic", Scrapers::CargurusScraper.normalize_transmission("CVT Automatic Transmission")
    assert_equal "Manual", Scrapers::CargurusScraper.normalize_transmission("6-Speed Manual")
    assert_nil Scrapers::CargurusScraper.normalize_transmission(nil)
  end
end
