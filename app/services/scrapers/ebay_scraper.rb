# eBay Motors actively pushes back against plain HTTP scraping (its
# search results only fully render, and its anti-bot checks only pass,
# once real browser JavaScript has run), so this scraper drives headless
# Chrome via `ferrum` the same way OfferupScraper does, then hands the
# rendered HTML to Nokogiri for the actual parsing -- a port of Python's
# `scrapers/ebay.py`, which used Playwright plus a stealth plugin for
# the same reason. Ferrum has no stealth equivalent, so this may get
# blocked more often than the Python version was; see the README.
module Scrapers
  class EbayScraper
    MAX_RESULTS = 45

    def self.scrape(search)
      html = fetch_html(search)
      return [] if html.blank?

      parse_listings(html, search)
    end

    # Loads eBay's homepage first (a "warm-up" visit, same trick the
    # Python version used, since eBay is more suspicious of a browser
    # that jumps straight to a search-results page with no prior visit)
    # and then the actual search URL, returning the rendered page's HTML.
    def self.fetch_html(search)
      browser = Ferrum::Browser.new(headless: true, timeout: 20, browser_path: ENV.fetch("BROWSER_PATH", nil))

      begin
        browser.go_to("https://www.ebay.com")
        sleep 2
        browser.go_to(search_url(search))
        sleep 3
        browser.body
      rescue Ferrum::Error => e
        Rails.logger.warn("[EbayScraper] fetch failed: #{e.message}")
        nil
      ensure
        browser.quit
      end
    end

    # Builds eBay's search URL: Used/Pre-Owned condition codes, Buy It
    # Now only (no auctions, since we want a fixed price to score
    # against), sorted by price ascending, capped at our absolute max
    # price -- matches Python's `_build_search_url` exactly.
    def self.search_url(search)
      query = "#{Listing::MIN_YEAR} #{search[:product_name]}"
      encoded = ERB::Util.url_encode(query)
      "https://www.ebay.com/sch/i.html" \
        "?_nkw=#{encoded}" \
        "&LH_ItemCondition=4|3|2|1500|1000|2000" \
        "&_sop=15" \
        "&_udlo=#{Listing::MIN_PRICE_USD.to_i}" \
        "&_udhi=#{Listing::ABSOLUTE_MAX_PRICE_USD.to_i}" \
        "&LH_BIN=1" \
        "&_ipg=120"
    end

    # Parses the rendered search-results HTML into listing hashes. Kept
    # separate from `fetch_html` so this (the part with real logic) can
    # be unit-tested against a fixture HTML string with no browser at all.
    def self.parse_listings(html, search)
      doc = Nokogiri::HTML(html)
      # eBay has changed its results markup more than once -- try the
      # current class names first, then fall back to the older ones,
      # same fallback chain the Python version used.
      items = doc.css("li.s-card")
      items = doc.css("div.s-card") if items.empty?
      items = doc.css("li.s-item") if items.empty?

      found = []
      found_ids = Set.new

      items.each do |item|
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
      title_el = item.at_css(".s-card__title") || item.at_css(".s-item__title")
      link_el = item.at_css("a.s-card__link") || item.at_css("a.s-item__link")
      return nil unless title_el && link_el

      title = clean_title(title_el.text.strip)
      return nil if title.blank? || title.include?("Shop on eBay")

      url = link_el["href"].to_s
      return nil if url.blank?

      price_el = item.at_css(".s-card__price") || item.at_css(".s-item__price")
      return nil unless price_el

      price_match = price_el.text.strip.match(/\$?([0-9,]+(?:\.[0-9]{2})?)/)
      return nil unless price_match

      price_usd = price_match[1].delete(",").to_f
      # Auction listings show "N bids" somewhere in the card -- skip
      # them, since an auction's current price isn't its final price.
      return nil if item.text.downcase.include?("bid")

      condition_el = item.at_css(".s-card__subtitle") || item.at_css(".s-item__subtitle")
      condition = condition_el&.text&.strip

      parsed = TitleParser.parse(title)
      return nil unless ListingFilter.passes?(
        title: title, condition: condition, price_usd: price_usd,
        parsed: parsed, expected_make: search[:make]
      )

      {
        source: "ebay",
        listing_id: listing_id_from(url),
        title: title,
        price_usd: price_usd,
        url: url,
        condition: condition,
        location: nil,
        seller_type: nil
      }.merge(parsed)
    end

    # eBay item URLs look like ".../itm/1234567890" -- that numeric ID
    # is stable and unique per listing, so it's what we key on.
    def self.listing_id_from(url)
      match = url.match(%r{/itm/(\d+)})
      return match[1] if match

      match = url.match(%r{/p/(\d+)})
      match ? "p_#{match[1]}" : "url_#{url.hash}"
    end

    # eBay's title text sometimes has screen-reader artifacts tacked on
    # ("...opens in a new window") -- strip those out so the title we
    # save and parse specs from is just the actual listing title.
    def self.clean_title(title)
      title.gsub(/\s*opens\s*(?:in\s*(?:a\s*)?new\s*(?:tab|window))?\s*\z/i, "")
           .gsub(/opens\s*\z/i, "")
           .gsub(/\s+/, " ")
           .strip
    end
  end
end
