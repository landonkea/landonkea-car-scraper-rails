# This is the ActiveRecord model for a single car listing --
# ActiveRecord is Rails' way of turning a database table (`listings`, from
# the migration next to this file) into a plain Ruby class you can query
# and manipulate with regular method calls instead of writing raw SQL.
# The actual title-parsing/filtering logic lives in TitleParser and the
# price-scoring logic lives in PriceAnalyzer -- this model mostly holds
# the shared thresholds both of those depend on, plus a few scoring
# helpers that only need a single listing (not a whole batch) to run.
class Listing < ApplicationRecord
  # Every search in the Python config.yaml used the exact same filters
  # (2015+, automatic, 4+ doors, clean title, under 150k miles) -- these
  # constants are that shared config, ported once instead of repeated
  # per car model the way config.yaml did.
  MIN_YEAR = 2015
  MAX_MILEAGE = 150_000
  MIN_DOORS = 4
  REQUIRED_TRANSMISSION = "Automatic"
  REQUIRED_TITLE_STATUS = "Clean"

  # The cheapest a listing can be and still be worth saving -- matches
  # Python's `MINIMUM_PRICE_USD` in product_types/cars.py. Below this,
  # it's almost certainly a parts listing or a typo, not a real car.
  MIN_PRICE_USD = 500
  # The most a listing can cost and still be in scope at all -- matches
  # `price.absolute_max_usd` in config.yaml.
  ABSOLUTE_MAX_PRICE_USD = 15_000
  # At or under this price, a listing is flagged as a "great deal" and
  # gets an immediate Discord alert -- matches `price.great_deal_usd.car`.
  GREAT_DEAL_PRICE_USD = 6_000
  # The next tier down -- still a good find, just not urgent-alert good --
  # matches `price.good_deal_usd.car`.
  GOOD_DEAL_PRICE_USD = 8_000
  # How many of the best-scoring listings from one car search get
  # included in a single Discord alert -- matches `price.top_deals_count`.
  TOP_DEALS_COUNT = 10

  # Makes generally considered reliable/desirable enough to earn a small
  # scoring bonus -- a direct port of the `reliable` list in
  # CarHandler#score_bonuses.
  RELIABLE_MAKES = %w[Honda Toyota Mazda Subaru Hyundai Kia].freeze

  # Every listing needs at minimum a source, a listing ID (so we can tell
  # duplicates apart), a title, a price, and a URL -- without those, the
  # scraper doesn't have enough to save a usable row, and the unique
  # index in the migration would reject a blank source/listing_id pair
  # anyway.
  validates :source, presence: true
  validates :listing_id, presence: true
  validates :title, presence: true
  validates :price_usd, presence: true
  validates :url, presence: true

  # `scope` defines a reusable, chainable query. `active` is listings our
  # last scrape run still confirmed were up -- this mirrors the
  # `WHERE is_active = true` filter Python's `expire_stale_listings`
  # relies on throughout main.py.
  scope :active, -> { where(is_active: true) }
  # Listings that cleared the "great deal" price bar.
  scope :great_deals, -> { where(is_great_deal: true) }
  # The default dashboard sort -- best score first, and among
  # equally-scored listings, cheapest first.
  scope :best_first, -> { order(deal_score: :desc, price_usd: :asc) }

  # `score_bonuses` is a straight port of Python's
  # `CarHandler#score_bonuses` -- it hands out points for the things that
  # make a car a genuinely better find (clean title, low miles, newer
  # year, a reliable make, hybrid fuel) independent of price. PriceAnalyzer
  # calls this once per listing and adds the result into the overall
  # deal_score.
  def spec_bonus
    bonus = 0.0

    # A clean title (no salvage/rebuilt history) is worth a full 15
    # points -- title problems are the single biggest red flag for a
    # used car, so a clean one gets rewarded heavily.
    bonus += 15 if title_status&.downcase == "clean"

    # Lower mileage is worth more, but the bonus tapers off in tiers
    # rather than scaling smoothly -- matches Python's exact bracket
    # values (15/10/5/2) rather than a continuous formula.
    if mileage
      bonus += if mileage < 50_000
        15
      elsif mileage < 80_000
        10
      elsif mileage < 100_000
        5
      elsif mileage < 120_000
        2
      else
        0
      end
    end

    # Newer model years get a bonus too, again in Python's exact tiers.
    if year
      bonus += if year >= 2020
        10
      elsif year >= 2018
        7
      elsif year >= 2016
        3
      else
        0
      end
    end

    # A small nudge for makes with a strong reliability reputation.
    bonus += 5 if make && RELIABLE_MAKES.include?(make)

    # Hybrids get a small bonus for lower running costs.
    bonus += 3 if fuel_type&.downcase == "hybrid"

    bonus
  end

  # `condition_bonus` ports the small condition-text bonus from
  # PriceAnalyzer#_score_listing in the Python version -- looks for a
  # few positive keywords in the free-text `condition` field some sites
  # provide.
  def condition_bonus
    return 0.0 unless condition

    lower = condition.downcase
    if lower.include?("new") || lower.include?("certified") || lower.include?("excellent")
      5.0
    elsif lower.include?("open")
      3.0
    elsif lower.include?("good")
      1.0
    else
      0.0
    end
  end

  # `seller_bonus` ports the "private party sellers usually have less
  # markup than dealers" bonus from the Python version.
  def seller_bonus
    seller_type == "private_party" ? 5.0 : 0.0
  end
end
