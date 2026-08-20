# Every scraper needs to run the exact same three-step filter on
# whatever raw listing it just parsed off a marketplace page: reject it
# outright for being irrelevant (wrong body type, parts-only, etc),
# reject it for not matching this search's year/mileage/doors/make
# requirements, or reject it for being priced outside our range. Pulling
# this into one shared helper means all four scrapers apply identical
# rules instead of each reimplementing (and risking drifting from) the
# same checks. A port of Python's `BaseScraper#passes_filters`, which
# every scraper subclass called at the end of its own parsing.
module Scrapers
  class ListingFilter
    # `passes?` takes the title/condition/price a scraper just parsed off
    # a listing card plus the already-extracted spec hash (from
    # TitleParser.parse) and the make this search is looking for, and
    # returns true only if the listing survives every check.
    def self.passes?(title:, condition:, price_usd:, parsed:, expected_make:)
      return false unless TitleParser.relevant?(title, condition)
      return false unless TitleParser.matches_search?(parsed, expected_make: expected_make)
      return false if price_usd < Listing::MIN_PRICE_USD
      return false if price_usd > Listing::ABSOLUTE_MAX_PRICE_USD

      true
    end
  end
end
