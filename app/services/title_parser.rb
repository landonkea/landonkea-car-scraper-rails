# Every marketplace hands us the same raw material for a car listing: a
# free-text title like "2018 Honda Fit LX Clean Title 45,000 mi Automatic"
# and, less often, a short condition string. None of the sites give us
# structured year/make/model/mileage fields directly (or the ones that
# do use inconsistent formats), so this class digs that structure back
# out of the title text with regular expressions. It's a straight port
# of Python's `product_types/cars.py` (the `CarHandler` class and its
# module-level `_extract_*` helper functions), kept as one file here
# since none of these pieces are useful on their own outside this app.
class TitleParser
  # Every make we know how to recognize in a title -- a listing whose
  # title doesn't mention one of these gets no `make` at all, which
  # later filters treat as "couldn't verify, don't reject outright."
  KNOWN_MAKES = [
    "Acura", "Audi", "BMW", "Buick", "Cadillac", "Chevrolet", "Chevy",
    "Chrysler", "Dodge", "Ford", "Genesis", "GMC", "Honda", "Hyundai",
    "Infiniti", "Jaguar", "Jeep", "Kia", "Land Rover", "Lexus",
    "Lincoln", "Mazda", "Mercedes-Benz", "Mercedes", "Mini",
    "Mitsubishi", "Nissan", "Pontiac", "Porsche", "Ram", "Subaru",
    "Suzuki", "Tesla", "Toyota", "Volkswagen", "Volvo"
  ].freeze

  # Phrases that mean "this isn't actually a whole car for sale" --
  # someone parting out a wreck, selling just a spare part, an owner's
  # manual, or a key fob. A title matching any of these gets rejected
  # entirely, title text or condition text alike.
  ACCESSORY_KEYWORDS = [
    "parts only", "for parts", "parting out", "part out",
    "engine only", "transmission only", "motor only",
    "tires only", "wheels only", "rim only", "rims only",
    "seat only", "door only", "hood only", "bumper only",
    "headlight only", "taillight only",
    "manual only", "owners manual", "key only", "fob only",
    "cover only", "mat only", "floor mats"
  ].freeze

  # Phrases describing a car in bad enough shape that it's not what
  # we're shopping for (a daily driver), even if it's technically for sale.
  BAD_CONDITION_KEYWORDS = [
    "does not run", "won't start", "wont start", "non-running",
    "non running", "not running", "no engine", "no transmission",
    "no motor", " blown engine", "blown motor",
    "flood damage", "fire damage", "frame damage"
  ].freeze

  # Body-type words that mean "this isn't a compact/subcompact sedan or
  # hatchback" -- we're specifically after small, cheap commuter cars,
  # not SUVs, trucks, or minivans.
  REJECTED_BODY_KEYWORDS = [
    "suv", "crossover", "truck", "pickup", "minivan", "van",
    "wagon", "convertible", "roadster",
    "4x4", "4wd", "awd", "4 wheel drive", "all wheel drive",
    "crew cab", "extended cab", "double cab", "towing",
    "bed liner", "bed cover", "tonneau"
  ].freeze

  # Specific model names that are NOT compact/subcompact even though
  # they might slip past the body-type keyword check above (e.g. an SUV
  # whose title never says "SUV") -- a direct port of Python's
  # `REJECTED_MODELS` list, organized the same way by make.
  REJECTED_MODELS = [
    "cr-v", "crv", "pilot", "odyssey", "ridgeline", "passport", "hr-v", "hrv",
    "rav4", "rav 4", "highlander", "4runner", "4 runner", "tacoma", "tundra",
    "sienna", "sequoia", "land cruiser", "venza", "corolla cross",
    "rogue", "murano", "pathfinder", "frontier", "titan", "armada", "kicks",
    "juke", "xterra",
    "sportage", "sorento", "seltos", "telluride", "carnival",
    "equinox", "traverse", "tahoe", "suburban", "colorado", "silverado",
    "blazer", "trailblazer", "trax",
    "escape", "explorer", "expedition", "edge", "bronco", "ranger",
    "f-150", "f150", "f-250", "f250", "f-350", "f350", "mustang",
    "tucson", "santa fe", "palisade", "kona", "venue",
    "outback", "forester", "crosstrek", "ascent", "tribeca",
    "cx-30", "cx-3", "cx-5", "cx-50", "cx-9", "cx-90",
    "cherokee", "compass", "renegade", "gladiator", "wrangler",
    "grand cherokee", "wagoneer",
    "outlander", "eclipse cross",
    "tiguan", "atlas", "taos",
    "1500", "2500", "3500",
    "journey", "durango",
    "encore", "envision", "enclave",
    "terrain", "acadia", "yukon", "canyon", "sierra",
    "patriot", "liberty", "commander"
  ].freeze

  # Words a matched model name shouldn't include -- these are sale-pitch
  # filler ("for sale," "clean title") that the naive "grab the words
  # after the make" regex below would otherwise scoop up as if they were
  # part of the model name.
  MODEL_STOP_WORDS = %w[
    for sale sell selling w/ with auto
    manual transmission engine miles mi
    clean title salvage rebuilt parts
    door sedan hatchback coupe suv
    gas diesel hybrid electric
    low new used great good excellent
    run runs drives driving
  ].freeze

  # `parse` runs every extractor below against one title and returns a
  # hash of whatever it could find -- mirrors Python's
  # `CarHandler#parse_specs`. Any field it couldn't determine comes back
  # as nil rather than raising, since most titles are missing at least
  # one of these.
  def self.parse(title)
    {
      year: extract_year(title),
      make: extract_make(title),
      model: extract_model(title),
      mileage: extract_mileage(title),
      transmission: extract_transmission(title),
      doors: extract_doors(title),
      title_status: extract_title_status(title),
      fuel_type: extract_fuel_type(title)
    }
  end

  # `relevant?` is the first filtering pass -- pure keyword rejection,
  # no numeric thresholds involved. A straight port of Python's
  # `CarHandler#is_relevant`.
  def self.relevant?(title, condition = nil)
    title_lower = title.to_s.downcase
    condition_lower = condition.to_s.downcase

    # Parts listings, manuals, and lone accessories aren't cars for sale.
    return false if ACCESSORY_KEYWORDS.any? { |kw| title_lower.include?(kw) || condition_lower.include?(kw) }
    # A car that can't run isn't a viable daily driver.
    return false if BAD_CONDITION_KEYWORDS.any? { |kw| title_lower.include?(kw) || condition_lower.include?(kw) }
    # We only want clean-title cars, so reject salvage/rebuilt outright
    # here rather than waiting for the later title_status filter.
    return false if title_lower.include?("salvage") || title_lower.include?("rebuilt")
    # Wrong body type (SUV, truck, van, etc).
    return false if REJECTED_BODY_KEYWORDS.any? { |kw| title_lower.include?(kw) }
    # Wrong specific model (an SUV/truck whose title never says so).
    return false if REJECTED_MODELS.any? { |model| title_lower.include?(model) }

    true
  end

  # `matches_search?` applies the numeric/exact-match filters -- year,
  # transmission, doors, title status, mileage, and (crucially) that the
  # make we parsed actually matches the make we were searching for, since
  # a search for "Honda Fit" can still surface a wrong-make listing on
  # sites like eBay that don't let us filter server-side. A port of
  # Python's `CarHandler#passes_type_filters`.
  def self.matches_search?(parsed, expected_make:)
    return false if parsed[:year] && parsed[:year] < Listing::MIN_YEAR
    return false if parsed[:transmission] && parsed[:transmission] != Listing::REQUIRED_TRANSMISSION
    return false if parsed[:doors] && parsed[:doors] < Listing::MIN_DOORS
    return false if parsed[:title_status] && parsed[:title_status] != Listing::REQUIRED_TITLE_STATUS
    return false if parsed[:mileage] && parsed[:mileage] > Listing::MAX_MILEAGE
    return false if expected_make && parsed[:make] && parsed[:make].downcase != expected_make.downcase

    true
  end

  # Finds a 4-digit year starting with "20" in the 2000s-2020s range --
  # matches Python's `\b(20[0-2]\d)\b` regex exactly.
  def self.extract_year(title)
    match = title.match(/\b(20[0-2]\d)\b/)
    match && match[1].to_i
  end

  # Finds the first known make mentioned anywhere in the title.
  def self.extract_make(title)
    title_lower = title.downcase
    KNOWN_MAKES.find { |make| title_lower.include?(make.downcase) }
  end

  # Grabs the word (or two) right after the make and strips out filler
  # words, e.g. "Honda Fit LX for sale" -> "Fit LX" -> stop-word filter
  # leaves "Fit LX". This is a heuristic, not a real catalog lookup, so
  # it can be wrong on unusual titles -- same trade-off the Python
  # version made.
  def self.extract_model(title)
    title_lower = title.downcase
    KNOWN_MAKES.each do |make|
      make_lower = make.downcase
      idx = title_lower.index(make_lower)
      next unless idx

      after_make = title_lower[(idx + make_lower.length)..].lstrip
      model_match = after_make.match(/\A([a-z0-9\-]+(?:\s+[a-z0-9\-]+)?)/)
      next unless model_match

      words = model_match[1].split.reject { |w| MODEL_STOP_WORDS.include?(w) }
      return words.join(" ") if words.any?
    end
    nil
  end

  # Mileage shows up in titles in a few different shapes ("45k miles",
  # "45,000 mi", or a bare "45000 miles") -- try each pattern from most
  # to least specific, same order Python checked them in.
  def self.extract_mileage(title)
    if (match = title.match(/\b(\d{1,3})k\s*(?:miles?|mi\.?)\b/i))
      return match[1].to_i * 1000
    end
    if (match = title.match(/\b(\d{1,3}(?:,\d{3})+)\s*(?:miles?|mi\.?)\b/i))
      return match[1].delete(",").to_i
    end
    if (match = title.match(/\b(\d{4,6})\s*(?:miles?|mi\.?)\b/i))
      value = match[1].to_i
      return value.positive? ? value : nil
    end
    nil
  end

  # Looks for explicit transmission words -- "CVT" gets checked
  # separately since it's neither automatic nor manual by name even
  # though it behaves like an automatic to a driver.
  def self.extract_transmission(title)
    title_lower = title.downcase
    return "Automatic" if %w[automatic].any? { |kw| title_lower.include?(kw) } || title_lower.include?("auto trans") || title_lower.include?("auto.")
    return "Manual" if %w[manual].any? { |kw| title_lower.include?(kw) } || title_lower.include?("stick shift") || title_lower.include?("5 speed") || title_lower.include?("6 speed")
    return "CVT" if title_lower.include?("cvt")

    nil
  end

  # A number right before the word "door" is the most reliable signal;
  # failing that, "sedan"/"hatchback" implies 4 doors and "coupe"
  # implies 2, same assumptions the Python version made.
  def self.extract_doors(title)
    if (match = title.match(/\b(\d)\s*door/i))
      return match[1].to_i
    end
    title_lower = title.downcase
    return 4 if %w[sedan].any? { |kw| title_lower.include?(kw) } || title_lower.include?("4 door") || title_lower.include?("four door")
    return 2 if %w[coupe].any? { |kw| title_lower.include?(kw) } || title_lower.include?("2 door") || title_lower.include?("two door")
    return 4 if title_lower.include?("hatchback")

    nil
  end

  # Title status words, checked most-specific first so "salvage title"
  # and a bare "salvage" both land on the same result.
  def self.extract_title_status(title)
    title_lower = title.downcase
    return "Salvage" if title_lower.include?("salvage title") || title_lower.include?("salvage")
    return "Rebuilt" if title_lower.include?("rebuilt title") || title_lower.include?("rebuilt")
    return "Clean" if title_lower.include?("clean title")
    return "Parts" if title_lower.include?("parts only")

    nil
  end

  # Fuel type words -- checked in this order so "hybrid" and "electric"
  # (both more specific/interesting to us) win over a generic "gas"
  # mention if a title somehow includes both.
  def self.extract_fuel_type(title)
    title_lower = title.downcase
    return "Hybrid" if title_lower.include?("hybrid")
    return "Electric" if title_lower.include?("electric") || title_lower.include?("ev")
    return "Diesel" if title_lower.include?("diesel")
    return "Gas" if %w[gas gasoline petrol].any? { |kw| title_lower.include?(kw) }

    nil
  end
end
