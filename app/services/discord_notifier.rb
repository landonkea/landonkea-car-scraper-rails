# Posts a "here are the best deals we found" message into a Discord
# channel via a webhook -- a webhook is just a special URL Discord gives
# you that accepts a JSON POST and turns it into a message, no bot login
# required. A port of Python's `Notifier#_send_discord`, trimmed down to
# just the core "top deals for one car search" alert (the Python version
# also had separate alert types for price drops, watchlist matches, and
# "great deal disappeared" -- this rewrite covers the alert every scrape
# run actually needs; see the README for more on that trade-off).
class DiscordNotifier
  # Discord's webhook API replies with a plain 204 No Content on success.
  SUCCESS_STATUS = 204
  # HTTP 429 is the standard "you're sending requests too fast" status.
  RATE_LIMITED_STATUS = 429

  # `send_alert` builds and posts one embed summarizing the top deals
  # found for a single car search (e.g. "Honda Fit"). `product_name` is
  # the human-readable search label, `top_deals` is an array of scored
  # Listing records (best first), and `stats` is the price-range hash
  # PriceAnalyzer computed for that same batch.
  def self.send_alert(product_name, top_deals, stats)
    return false if top_deals.empty?

    webhook_url = ENV.fetch("DISCORD_WEBHOOK_URL", nil)
    if webhook_url.blank?
      Rails.logger.info("[DiscordNotifier] no webhook configured, skipping alert for: #{product_name}")
      return false
    end

    best = top_deals.first
    # Green if the very best listing found is a great deal, amber
    # otherwise -- matches Python's exact color choice and hex values.
    color = best.is_great_deal? ? 0x00ff00 : 0xffaa00

    market_field = {
      name: "Market Snapshot",
      value: "**#{stats[:count]}** listings found\n" \
             "Price range: **#{format_price(stats[:min])}** - **#{format_price(stats[:max])}**\n" \
             "Median: **#{format_price(stats[:median])}**",
      inline: false
    }

    listing_fields = top_deals.each_with_index.map { |listing, index| listing_field(listing, index + 1) }

    embed = {
      title: "#{product_name} Deal Alert",
      color: color,
      fields: [ market_field ] + listing_fields,
      footer: { text: product_name }
    }

    post_embed(webhook_url, embed)
  end

  # Builds one field describing a single listing -- rank, price, source,
  # and the car info/mileage/score/age line underneath, matching the
  # exact layout Python's embed used.
  def self.listing_field(listing, rank)
    emoji = listing.is_great_deal? ? "!" : "$"
    car_info = "#{listing.year || '?'} #{listing.make || '?'} #{listing.model || '?'}"
    mileage_str = listing.mileage ? "#{ActiveSupport::NumberHelper.number_to_delimited(listing.mileage)}mi" : "?"
    age = listing_age(listing.first_seen_at)
    age_suffix = age.present? ? ", #{age}" : ""

    {
      name: "#{emoji} ##{rank}, #{format_price(listing.price_usd)} | #{listing.source}",
      value: "[#{car_info} - #{mileage_str}](#{listing.url}), Score: #{listing.deal_score}/100#{age_suffix}",
      inline: false
    }
  end

  # Renders a dollar amount the way Discord embeds show it throughout
  # this notifier -- whole dollars, comma-separated, e.g. "$6,000".
  def self.format_price(amount)
    "$#{ActiveSupport::NumberHelper.number_to_delimited(amount.round)}"
  end

  # Renders how long ago a listing first appeared, as a short string
  # like "Listed 4h ago" -- matches Python's `format_listing_age`.
  def self.listing_age(first_seen_at)
    return "" unless first_seen_at

    seconds = [ Time.current - first_seen_at, 0 ].max
    hours = seconds / 3600.0
    days = hours / 24.0

    if hours < 1
      "Listed #{[ (seconds / 60).to_i, 1 ].max}m ago"
    elsif days < 1
      "Listed #{hours.to_i}h ago"
    else
      "Listed #{days.to_i}d ago"
    end
  end

  # Pulled out on its own so the retry-on-429 logic doesn't clutter up
  # `send_alert` above -- identical retry behavior to Python's version.
  def self.post_embed(webhook_url, embed)
    response = Faraday.post("#{webhook_url}?wait=true") do |req|
      req.headers["Content-Type"] = "application/json"
      req.options.timeout = 15
      req.body = { username: "Car Scraper", embeds: [ embed ] }.to_json
    end

    if response.status == SUCCESS_STATUS
      true
    elsif response.status == RATE_LIMITED_STATUS
      # Discord tells us exactly how long to wait in the response body;
      # pad it by half a second, same as the Python version, then try
      # exactly once more.
      retry_after = JSON.parse(response.body)["retry_after"] || 2
      sleep(retry_after + 0.5)
      retry_response = Faraday.post("#{webhook_url}?wait=true") do |req|
        req.headers["Content-Type"] = "application/json"
        req.options.timeout = 15
        req.body = { username: "Car Scraper", embeds: [ embed ] }.to_json
      end
      retry_response.status == SUCCESS_STATUS
    else
      Rails.logger.warn("[DiscordNotifier] unexpected status #{response.status}")
      false
    end
  rescue Faraday::Error => e
    # Network hiccups shouldn't crash the scraper -- log it and move on.
    Rails.logger.warn("[DiscordNotifier] request failed: #{e.message}")
    false
  end
end
