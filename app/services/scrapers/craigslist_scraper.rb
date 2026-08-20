# Pulls car listings straight off Craigslist's static search-results
# HTML. Craigslist's pages are plain server-rendered markup -- a normal
# HTTP GET plus an HTML parser is enough, the same way Python's version
# used `requests` + BeautifulSoup instead of Playwright for this one
# site (every other marketplace here needs a real browser; Craigslist
# doesn't). A port of Python's `scrapers/craigslist.py`.
module Scrapers
  class CraigslistScraper
    # Every Arizona-area Craigslist region the Python config.yaml's
    # `locations` list covered, deduplicated down to Craigslist's own
    # region subdomains (several AZ cities share one Craigslist region).
    REGIONS = %w[phoenix tucson flagstaff yuma prescott mohave showlow sierravista].freeze

    # How many matching listings we'll collect for one car search before
    # we stop paging through regions -- matches every search's
    # `results_per_size: 45` in the Python config.yaml.
    MAX_RESULTS = 45

    # Craigslist's cars+trucks category code -- using this instead of
    # "sss" (all-for-sale) keeps results scoped to actual vehicles.
    CATEGORY = "cta"

    USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36".freeze

    # `scrape` runs one car search (e.g. "Honda Fit") across every AZ
    # region and returns an array of listing hashes that already passed
    # ListingFilter -- ready for ScrapeRunner to save. `search` is a hash
    # with :product_name and :make keys.
    def self.scrape(search)
      found = []
      found_ids = Set.new

      REGIONS.each do |region|
        break if found.length >= MAX_RESULTS

        begin
          scrape_region(region, search, found, found_ids)
        rescue Faraday::Error => e
          # One region failing (timeout, bad HTML, whatever) shouldn't
          # take down the other seven -- matches Python's per-region
          # try/except in main.py's `get_enabled_scrapers` loop.
          Rails.logger.warn("[CraigslistScraper] #{region} failed: #{e.message}")
        end
      end

      found
    end

    def self.scrape_region(region, search, found, found_ids)
      response = Faraday.get(search_url(region, search)) do |req|
        req.headers["User-Agent"] = USER_AGENT
        req.options.timeout = 30
      end

      # Nokogiri::HTML turns the raw HTML string into a searchable
      # document tree -- the Ruby equivalent of BeautifulSoup's parser.
      doc = Nokogiri::HTML(response.body)

      doc.css("li.cl-static-search-result").each do |item|
        break if found.length >= MAX_RESULTS

        listing = parse_item(item, search)
        next unless listing
        next if found_ids.include?(listing[:listing_id])

        found << listing
        found_ids << listing[:listing_id]
      end
    end

    # Builds the search URL for one region -- Craigslist's consolidated
    # `/search/area/{region}` shape lets us pass `cat=cta` (cars+trucks)
    # plus a free-text query and a max price, matching Python's
    # `_build_search_url` exactly.
    def self.search_url(region, search)
      query = ERB::Util.url_encode(search[:product_name])
      "https://www.craigslist.org/search/area/#{region}" \
        "?cat=#{CATEGORY}&query=#{query}&max_price=#{Listing::ABSOLUTE_MAX_PRICE_USD.to_i}"
    end

    # Parses one `<li class="cl-static-search-result">` card into a
    # listing hash, or returns nil if the card is missing something we
    # can't do without (a title, a link, a price) or doesn't pass our
    # filters.
    def self.parse_item(item, search)
      title = item.at_css("div.title")&.text&.strip
      return nil if title.blank?

      href = item.at_css("a")&.[]("href")
      return nil if href.blank?

      price_text = item.at_css("div.price")&.text
      return nil if price_text.blank?

      price_match = price_text.match(/(\d[\d,.]*)/)
      return nil unless price_match

      price_usd = price_match[1].delete(",").to_f
      location = item.at_css("div.location")&.text&.strip

      # A card's full visible text mentioning "dealer"/"dealership"
      # anywhere is Craigslist's usual tell for a dealer posting rather
      # than a private-party one.
      item_text = item.text.downcase
      seller_type = item_text.include?("dealer") ? "dealer" : "private_party"

      parsed = TitleParser.parse(title)
      return nil unless ListingFilter.passes?(
        title: title, condition: nil, price_usd: price_usd,
        parsed: parsed, expected_make: search[:make]
      )

      segment = href.to_s.chomp("/").rpartition("/").last

      {
        source: "craigslist",
        listing_id: "craigslist-#{segment}",
        title: title,
        price_usd: price_usd,
        url: href,
        condition: nil,
        location: location,
        seller_type: seller_type
      }.merge(parsed)
    end
  end
end
