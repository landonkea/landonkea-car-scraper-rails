# Turns a batch of already-saved Listing rows (all from the same car
# search, e.g. every "Honda Fit" listing found this run) into 0-100 deal
# scores, by comparing each listing's price against the group's own
# median rather than some fixed price table. A direct port of Python's
# `PriceAnalyzer` class in price_analyzer.py, with one deliberate cut:
# the Python version also compared each price against a scraped KBB
# market-value estimate (kbb.py) for up to a +15 bonus -- that depended
# on a separate static price-lookup table this rewrite doesn't carry
# over, so that particular bonus is dropped. See the README for more on
# that trade-off.
class PriceAnalyzer
  # A listing suspiciously far under the group's median (less than half
  # of it) AND described with words like "new"/"sealed" is more likely a
  # scam or a typo than an actual bargain -- matches Python's
  # `SUSPICIOUS_PRICE_RATIO`/`SUSPICIOUS_MIN_SAMPLE`.
  SUSPICIOUS_PRICE_RATIO = 0.5
  SUSPICIOUS_MIN_SAMPLE = 3
  SUSPICIOUS_CONDITION_KEYWORDS = [ "new", "sealed", "brand new", "factory sealed" ].freeze

  # How much each marketplace's listings are trusted, added straight
  # into the score -- dealer-heavy sites like CarGurus/AutoTrader trend
  # slightly positive (cleaner listings, verified prices), while
  # classifieds sites with less moderation trend slightly negative. A
  # direct port of Python's `DEFAULT_SOURCE_RELIABILITY_BONUS`.
  SOURCE_RELIABILITY_BONUS = {
    "craigslist" => -3,
    "offerup" => -3,
    "facebook" => -1,
    "ebay" => 0,
    "cargurus" => 1,
    "autotrader" => 1
  }.freeze

  # `call` is the one entry point -- takes an array of Listing records
  # (already saved to the database) that all came from the same car
  # search, scores every one of them, saves the scores back to the
  # database, and returns the same array sorted best-score-first so the
  # caller can hand the top of it straight to DiscordNotifier.
  def self.call(listings)
    new(listings).call
  end

  def initialize(listings)
    @listings = listings
  end

  def call
    stats = compute_stats

    @listings.each do |listing|
      score = score_listing(listing, stats)
      great_deal = listing.price_usd <= Listing::GREAT_DEAL_PRICE_USD
      # A suspiciously-cheap listing never counts as a "great deal" even
      # if its raw price clears the threshold -- it's more likely wrong
      # than it is a steal.
      great_deal = false if suspicious?(listing, stats)

      listing.update!(deal_score: score, is_great_deal: great_deal)
    end

    @listings.sort_by { |listing| -(listing.deal_score || 0) }
  end

  # Exposed so ScrapeRunner/DiscordNotifier can show the group's price
  # range and median alongside the individual listing scores, the same
  # "Market Snapshot" field Python's Discord embed includes.
  def stats
    @stats ||= compute_stats
  end

  private

  def compute_stats
    return { count: 0, mean: 0.0, median: 0.0, min: 0.0, max: 0.0 } if @listings.empty?

    prices = @listings.map(&:price_usd).sort
    n = prices.length

    {
      count: n,
      mean: (prices.sum / n).round(2),
      median: median(prices),
      min: prices.first,
      max: prices.last
    }
  end

  def median(sorted_prices)
    n = sorted_prices.length
    mid = n / 2
    n.odd? ? sorted_prices[mid] : ((sorted_prices[mid - 1] + sorted_prices[mid]) / 2.0)
  end

  # When there's only one listing (or none) in the group, there's no
  # meaningful median to compare against -- fall back to the flat
  # price-tier scoring Python used for that same edge case.
  def score_listing(listing, stats)
    return baseline_score(listing) if stats[:count] <= 1

    score = 50.0

    # The bigger the discount below the group median, the bigger the
    # bonus (capped at +30); priced above median costs points too, but
    # more gently (capped at -20) -- matches Python's exact ratios and caps.
    median = stats[:median]
    if median.positive?
      if listing.price_usd < median
        ratio = (median - listing.price_usd) / median
        score += [ ratio * 100, 30 ].min
      else
        ratio = (listing.price_usd - median) / median
        score -= [ ratio * 50, 20 ].min
      end
    end

    score += listing.condition_bonus
    score += SOURCE_RELIABILITY_BONUS.fetch(listing.source, 0)
    score += listing.seller_bonus
    score += listing.spec_bonus

    score = score.clamp(0, 100)
    score = [ score, 10.0 ].min if suspicious?(listing, stats)

    score.round(1)
  end

  # Mirrors Python's "no batch data" fallback: flat scores keyed off the
  # fixed great/good-deal price thresholds instead of a median comparison.
  def baseline_score(listing)
    if listing.price_usd <= Listing::GREAT_DEAL_PRICE_USD
      90.0
    elsif listing.price_usd <= Listing::GOOD_DEAL_PRICE_USD
      70.0
    else
      40.0
    end
  end

  def suspicious?(listing, stats)
    return false if stats[:median].to_f <= 0 || stats[:count] < SUSPICIOUS_MIN_SAMPLE
    return false if listing.price_usd >= stats[:median] * SUSPICIOUS_PRICE_RATIO

    text = "#{listing.condition} #{listing.title}".downcase
    SUSPICIOUS_CONDITION_KEYWORDS.any? { |kw| text.include?(kw) }
  end
end
