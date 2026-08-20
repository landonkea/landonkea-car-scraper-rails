# OfferUp is a JavaScript single-page app -- there's no plain HTML we
# could fetch and parse the way we do for Craigslist, so this scraper
# drives an actual headless Chrome browser (via the `ferrum` gem) to
# load the search page and let React render it, then reads the listing
# data back out of Next.js's own embedded `__NEXT_DATA__` JSON blob
# (every Next.js-built site, OfferUp included, stuffs its page data into
# a `<script id="__NEXT_DATA__">` tag -- reading that is far more
# reliable than trying to guess at CSS selectors for a UI that changes
# often). A trimmed port of Python's `scrapers/offerup.py`: the Python
# version also had three separate HTML-scraping fallback strategies for
# when `__NEXT_DATA__` isn't present; this rewrite keeps only the
# primary (and most reliable) path. See the README for more on that
# trade-off, and note that Ferrum has no equivalent to the
# playwright-stealth anti-bot-detection tricks the Python version used,
# so this may get blocked more often than the original did.
module Scrapers
  class OfferupScraper
    MAX_RESULTS = 45

    # `scrape` is the public entry point -- fetches raw listing JSON via
    # a real browser, then parses/filters it down to matches for this
    # search. Split into two steps so `parse_listings` (the part with
    # actual logic worth testing) can be exercised directly with fixture
    # JSON, with no browser involved.
    def self.scrape(search)
      raw_items = fetch_listings_json(search)
      parse_listings(raw_items, search)
    end

    # Launches headless Chrome, loads OfferUp's search page for this
    # car's name, and pulls the listing array back out of the page's
    # `__NEXT_DATA__` script tag. Any browser failure (timeout, OfferUp
    # blocking us, Chrome missing) is swallowed and logged rather than
    # raised, so one marketplace failing doesn't stop the whole scrape run.
    def self.fetch_listings_json(search)
      url = "https://offerup.com/search/?q=#{ERB::Util.url_encode(search[:product_name])}"
      browser = Ferrum::Browser.new(headless: true, timeout: 20, browser_path: ENV.fetch("BROWSER_PATH", nil))

      begin
        browser.go_to(url)
        sleep 3

        raw_json = browser.evaluate(<<~JS)
          (() => {
            const el = document.getElementById('__NEXT_DATA__');
            return el ? el.textContent : null;
          })()
        JS
        return [] if raw_json.blank?

        data = JSON.parse(raw_json)
        tiles = data.dig("props", "pageProps", "searchFeedResponse", "looseTiles") || []
        tiles.filter_map { |tile| tile["listing"] if tile["__typename"] == "ModularFeedTileListing" }
      rescue Ferrum::Error, JSON::ParserError => e
        Rails.logger.warn("[OfferupScraper] fetch failed: #{e.message}")
        []
      ensure
        browser.quit
      end
    end

    # Turns OfferUp's raw listing JSON items into our listing hashes,
    # keeping only ones that pass ListingFilter, and stopping once we've
    # got enough for this search.
    def self.parse_listings(raw_items, search)
      found = []
      found_ids = Set.new

      raw_items.each do |item|
        break if found.length >= MAX_RESULTS

        listing = parse_listing(item, search)
        next unless listing
        next if found_ids.include?(listing[:listing_id])

        found << listing
        found_ids << listing[:listing_id]
      end

      found
    end

    def self.parse_listing(item, search)
      title = item["title"]
      return nil if title.blank?

      price_usd = item["price"].to_s.delete("$,").to_f
      return nil unless price_usd.positive?

      listing_id = item["listingId"]
      return nil if listing_id.blank?

      condition = item["conditionText"].presence || "Used"
      location = item["locationName"] || item["location"]

      parsed = TitleParser.parse(title)
      return nil unless ListingFilter.passes?(
        title: title, condition: condition, price_usd: price_usd,
        parsed: parsed, expected_make: search[:make]
      )

      {
        source: "offerup",
        listing_id: listing_id,
        title: title,
        price_usd: price_usd,
        url: "https://offerup.com/item/detail/#{listing_id}",
        condition: condition,
        location: location,
        seller_type: nil
      }.merge(parsed)
    end
  end
end
