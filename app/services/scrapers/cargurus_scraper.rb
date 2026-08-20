# CarGurus blocks plain HTTP requests and headless browsers it detects
# as automated, so this scraper (like the Python version) drives a real
# headless Chrome via `ferrum` and points it straight at CarGurus's own
# internal JSON search API (`searchResults.action`) rather than trying
# to parse their HTML -- the API is what CarGurus's own site JavaScript
# calls to fill the page, so reading it directly is both simpler and
# more stable than scraping rendered markup. A port of Python's
# `scrapers/cargurus.py`. Ferrum has no equivalent to the
# playwright-stealth plugin the Python version paired with this same
# technique, so this may get blocked more often; see the README.
module Scrapers
  class CargurusScraper
    MAX_RESULTS = 45

    # CarGurus assigns each car model an internal "entity ID" used to
    # filter its search API -- Python only ever mapped the four models
    # it needed most (this rewrite keeps that same, incomplete map
    # rather than inventing new IDs we can't verify). A search for any
    # other model still runs, just without CarGurus-side model
    # filtering -- ListingFilter catches wrong-make results afterward.
    ENTITY_IDS = {
      "honda fit" => "d744",
      "chevy spark" => "d906",
      "chevrolet spark" => "d906",
      "nissan versa" => "d937",
      "kia rio" => "d159"
    }.freeze

    def self.scrape(search)
      raw_items = fetch_json_listings(search)
      parse_listings(raw_items, search)
    end

    # Every Arizona zip code from the Python config.yaml `locations`
    # list would be excessive to hit one by one here -- CarGurus returns
    # results for a wide radius around a single zip, so one representative
    # zip per major AZ metro area is enough coverage without tripling our
    # request count for near-identical results.
    ZIP_CODES = %w[85001 85701 86001].freeze

    def self.fetch_json_listings(search)
      entity_id = ENTITY_IDS[search[:product_name].downcase] || entity_id_for(search)
      browser = Ferrum::Browser.new(headless: true, timeout: 20, browser_path: ENV.fetch("BROWSER_PATH", nil))
      all_listings = []

      begin
        ZIP_CODES.each do |zip|
          url = api_url(zip, entity_id)
          begin
            browser.go_to(url)
            sleep 2
            body = browser.evaluate("document.body.innerText")
            all_listings.concat(JSON.parse(body)) if body.strip.start_with?("[")
          rescue Ferrum::Error, JSON::ParserError => e
            Rails.logger.warn("[CargurusScraper] zip=#{zip} failed: #{e.message}")
          end
        end
      ensure
        browser.quit
      end

      all_listings
    end

    # Looks up the entity ID by whichever known key is a substring of
    # the search's product name, matching Python's fuzzy `in` check
    # rather than requiring an exact key match.
    def self.entity_id_for(search)
      key = ENTITY_IDS.keys.find { |k| search[:product_name].downcase.include?(k) }
      key ? ENTITY_IDS[key] : ""
    end

    def self.api_url(zip, entity_id)
      "https://www.cargurus.com/Cars/searchResults.action" \
        "?zip=#{zip}&inventorySearchWidgetType=AUTO&sortDir=ASC&sortType=PRICE" \
        "&offset=0&maxResults=100&filtersModified=true" \
        "&entitySelectingHelper.selectedEntity=#{entity_id}"
    end

    def self.parse_listings(raw_items, search)
      found = []
      found_ids = Set.new

      raw_items.each do |item|
        break if found.length >= MAX_RESULTS

        listing = parse_item(item, search)
        next unless listing
        next if found_ids.include?(listing[:listing_id])

        found << listing
        found_ids << listing[:listing_id]
      end

      found
    end

    def self.parse_item(item, search)
      title = item["listingTitle"]
      return nil if title.blank?

      price_usd = item["price"].to_f
      return nil unless price_usd.positive?

      cargurus_id = item["id"]
      return nil if cargurus_id.blank?

      mileage = item.dig("unitMileage", "value")
      mileage = mileage.to_i if mileage

      transmission = normalize_transmission(item["localizedTransmission"])
      city = item["sellerCity"]
      location = city.present? ? "#{city}, #{item['sellerRegion']}" : nil
      seller_type = item["sellerType"].to_s.upcase == "PRIVATE_PARTY" ? "private_party" : "dealer"

      parsed = TitleParser.parse(title)
      # CarGurus supplies its own year/make/model/mileage/transmission
      # fields alongside the title -- prefer whatever TitleParser found
      # in the title text, but fall back to CarGurus's own structured
      # data when the title-parsing heuristic came up empty, same
      # priority order Python used.
      merged = parsed.merge(
        year: parsed[:year] || item["carYear"],
        make: parsed[:make] || item["makeName"],
        model: parsed[:model] || item["modelName"],
        mileage: parsed[:mileage] || mileage,
        transmission: parsed[:transmission] || transmission
      )

      return nil unless ListingFilter.passes?(
        title: title, condition: "Used", price_usd: price_usd,
        parsed: merged, expected_make: search[:make]
      )

      {
        source: "cargurus",
        listing_id: "cargurus-#{cargurus_id}",
        title: title,
        price_usd: price_usd,
        url: "https://www.cargurus.com/Cars/details/#{cargurus_id}",
        condition: "Used",
        location: location,
        seller_type: seller_type
      }.merge(merged)
    end

    def self.normalize_transmission(raw)
      return nil if raw.blank?

      lower = raw.downcase
      return "Automatic" if lower.include?("automatic") || lower.include?("cvt")
      return "Manual" if lower.include?("manual")

      nil
    end
  end
end
