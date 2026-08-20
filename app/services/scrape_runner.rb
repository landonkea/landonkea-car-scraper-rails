# The entry point that ties every scraper together, same job Python's
# main.py did: for each car model we're watching, scrape all four
# marketplaces, save/update the listings we found, score them against
# each other, and alert Discord if anything new or great turned up.
# This is what the recurring background job (see
# app/jobs/scrape_listings_job.rb) actually calls.
class ScrapeRunner
  # Every car search the Python config.yaml ran, reduced to just the two
  # things that actually differ between searches (everything else --
  # min year, max mileage, transmission, doors, title status, min
  # price -- was identical across all 18 entries in the original config,
  # so those live as shared constants on Listing instead of being
  # repeated 18 times here).
  CAR_SEARCHES = [
    { product_name: "Toyota Yaris (2015+, automatic)", make: "Toyota" },
    { product_name: "Toyota Corolla (2015+, automatic)", make: "Toyota" },
    { product_name: "Honda Civic (2015+, automatic)", make: "Honda" },
    { product_name: "Hyundai Accent (2015+, automatic)", make: "Hyundai" },
    { product_name: "Kia Forte (2015+, automatic)", make: "Kia" },
    { product_name: "Hyundai Elantra (2015+, automatic)", make: "Hyundai" },
    { product_name: "Mitsubishi Mirage (2015+, automatic)", make: "Mitsubishi" },
    { product_name: "Ford Fiesta (2015+, automatic)", make: "Ford" },
    { product_name: "Ford Focus (2015+, automatic)", make: "Ford" },
    { product_name: "Mazda 3 (2015+, automatic)", make: "Mazda" },
    { product_name: "Chevrolet Cruze (2015+, automatic)", make: "Chevrolet" },
    { product_name: "Kia Soul (2015+, automatic)", make: "Kia" },
    { product_name: "Volkswagen Jetta (2015+, automatic)", make: "Volkswagen" },
    { product_name: "Subaru Impreza (2015+, automatic)", make: "Subaru" },
    { product_name: "Honda Fit (2015+, automatic)", make: "Honda" },
    { product_name: "Chevy Spark (2015+, automatic)", make: "Chevrolet" },
    { product_name: "Nissan Versa (2015+, automatic)", make: "Nissan" },
    { product_name: "Kia Rio (2015+, automatic)", make: "Kia" }
  ].freeze

  # Every marketplace scraper this app knows how to run, in the same
  # order the Python version ran them (fast plain-HTTP sites first,
  # slower browser-driven sites after).
  SCRAPERS = [ Scrapers::CraigslistScraper, Scrapers::OfferupScraper, Scrapers::EbayScraper, Scrapers::CargurusScraper ].freeze

  # A listing not re-confirmed by any scraper in this many hours is
  # treated as sold/removed -- matches Python's `expire_stale_listings(hours=72)`.
  STALE_HOURS = 72
  # Listings inactive for this many days get permanently deleted rather
  # than kept forever -- matches Python's `RETENTION_DAYS = 180`.
  RETENTION_DAYS = 180

  # `call` is the single method the job needs to invoke -- runs every
  # car search in sequence and logs a short summary, mirroring the flow
  # of Python's `run_scrape()`.
  def self.call
    Rails.logger.info("[ScrapeRunner] starting scrape at #{Time.current}")

    expired = expire_stale_listings
    Rails.logger.info("[ScrapeRunner] expired #{expired} listing(s) not seen in #{STALE_HOURS}h") if expired.positive?

    pruned = prune_old_inactive_listings
    Rails.logger.info("[ScrapeRunner] pruned #{pruned} listing(s) inactive for #{RETENTION_DAYS}+ days") if pruned.positive?

    totals = { saved: 0, new: 0, alerts_sent: 0 }

    CAR_SEARCHES.each do |search|
      result = run_search(search)
      totals[:saved] += result[:saved]
      totals[:new] += result[:new]
      totals[:alerts_sent] += 1 if result[:alert_sent]
    end

    Rails.logger.info(
      "[ScrapeRunner] done - #{totals[:saved]} saved/updated, " \
      "#{totals[:new]} new, #{totals[:alerts_sent]} alert(s) sent"
    )
    totals
  end

  # Runs one car search end-to-end: scrape every marketplace, save what
  # was found, score the batch, and alert if warranted. Public (not
  # private) so it can be called directly from the console or a test
  # without running all 18 searches.
  def self.run_search(search)
    Rails.logger.info("[ScrapeRunner] searching: #{search[:product_name]}")

    # Run every marketplace for this one car model and flatten their
    # results into a single list -- one scraper failing (network error,
    # site blocking us, whatever) shouldn't stop the others from
    # contributing, so each is wrapped in its own rescue.
    scraped = SCRAPERS.flat_map do |scraper|
      scraper.scrape(search)
    rescue StandardError => e
      Rails.logger.warn("[ScrapeRunner] #{scraper.name} failed for #{search[:product_name]}: #{e.message}")
      []
    end

    db_listings = []
    new_count = 0

    scraped.each do |attrs|
      # `find_or_initialize_by` on (source, listing_id) is what makes
      # re-running this safe: a listing we've already saved gets its
      # fields refreshed (price changes show up), while a listing we
      # haven't seen before gets a brand new row -- matches Python's
      # `listing_to_db` upsert logic.
      listing = Listing.find_or_initialize_by(source: attrs[:source], listing_id: attrs[:listing_id])
      is_new = listing.new_record?

      listing.assign_attributes(attrs.except(:source, :listing_id))
      listing.first_seen_at ||= Time.current
      listing.last_seen_at = Time.current
      listing.is_active = true
      listing.save!

      db_listings << listing
      new_count += 1 if is_new
    end

    return { saved: 0, new: 0, alert_sent: false } if db_listings.empty?

    # Score this search's listings against each other (not against
    # every other car model's listings) -- matches Python creating a
    # fresh `PriceAnalyzer` per search rather than one shared across
    # the whole run.
    analyzer = PriceAnalyzer.new(db_listings)
    sorted = analyzer.call
    top_deals = sorted.first(Listing::TOP_DEALS_COUNT)

    # Only bother alerting if there's something new to see, or if one
    # of the top deals is flagged as a great deal -- matches Python's
    # `if new_listings or has_great_deals: notifier.send_alert(...)`.
    has_great_deal = top_deals.any?(&:is_great_deal?)
    alert_sent = false
    if new_count.positive? || has_great_deal
      alert_sent = DiscordNotifier.send_alert(search[:product_name], top_deals, analyzer.stats)
    end

    { saved: db_listings.size, new: new_count, alert_sent: alert_sent }
  end

  # Marks any listing not re-confirmed by this run's scrapers as
  # inactive -- returns how many rows were flipped. `update_all` skips
  # loading each record into memory since we don't need callbacks for a
  # bulk status flip.
  def self.expire_stale_listings
    Listing.active.where("last_seen_at < ?", STALE_HOURS.hours.ago).update_all(is_active: false)
  end

  # Permanently deletes listings that have been inactive for a long
  # time -- keeps the table from growing forever with cars that sold
  # months ago, while still giving a sold listing a generous window
  # (180 days) before it's gone for good.
  def self.prune_old_inactive_listings
    Listing.where(is_active: false).where("last_seen_at < ?", RETENTION_DAYS.days.ago).delete_all
  end
end
