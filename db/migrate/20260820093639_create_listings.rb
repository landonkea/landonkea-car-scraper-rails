# This migration is the Ruby version of the Python project's SQLAlchemy
# `Listing` model in database.py -- it builds the one table this whole
# app cares about: every cheap small car we've ever found on Craigslist,
# OfferUp, eBay, or CarGurus.
class CreateListings < ActiveRecord::Migration[8.1]
  # Rails calls this method to figure out what to do; `change` lets Rails
  # work out the up/down migration automatically since everything below is
  # a simple, reversible operation (just creating a table and some indexes).
  def change
    # `create_table :listings` opens up the block below and, once it runs,
    # issues the actual `CREATE TABLE listings (...)` SQL against the database.
    create_table :listings do |t|
      # Which marketplace this came from -- "craigslist", "offerup",
      # "ebay", or "cargurus". Matches the Python `source` column exactly.
      t.string :source, null: false
      # The marketplace's own ID for this listing (pulled from its URL) --
      # this, combined with `source`, is how we tell "we've already seen
      # this exact listing" from "this is a brand new one."
      t.string :listing_id, null: false
      # The listing's title/headline text, e.g. "2018 Honda Fit LX 45k mi".
      t.string :title, null: false
      # The asking price in US dollars. Float (not integer) because some
      # listings show cents, matching the Python `price_usd` column.
      t.float :price_usd, null: false
      # The actual link to the listing on the source site -- what the
      # Discord alert points people to, and what the dashboard links out to.
      t.text :url, null: false
      # Free-text condition string some sites provide (e.g. "Used", "Good") --
      # optional since not every marketplace exposes one.
      t.string :condition
      # Free-text city/neighborhood string, e.g. "Tempe, AZ" -- optional
      # since not every marketplace exposes one either.
      t.string :location

      # ── Car-specific fields, all parsed out of the title by TitleParser ──
      # The model year, e.g. 2019. Nil if we couldn't find a 4-digit year.
      t.integer :year
      # The manufacturer, e.g. "Honda". Nil if no known make matched.
      t.string :make
      # The specific model, e.g. "Fit" or "Civic Si". Nil if we couldn't
      # isolate one after the make.
      t.string :model
      # Odometer reading in miles. Nil if the title didn't mention mileage.
      t.integer :mileage
      # "Automatic", "Manual", or "CVT" -- nil if the title didn't say.
      t.string :transmission
      # Door count (2 or 4) -- nil if we couldn't infer it from the title.
      t.integer :doors
      # "Clean", "Salvage", "Rebuilt", or "Parts" -- nil if unmentioned.
      t.string :title_status
      # "Gas", "Hybrid", "Electric", or "Diesel" -- nil if unmentioned.
      t.string :fuel_type
      # "dealer" or "private_party" -- only a few sources (Craigslist,
      # CarGurus) let us tell these apart; nil everywhere else.
      t.string :seller_type

      # ── Deal scoring, computed by PriceAnalyzer once per scrape ──
      # A 0-100 score: how good a deal this listing is compared to the
      # other listings found for the same car search. Nil until scored.
      t.float :deal_score
      # True if the price is at or under our "great deal" threshold --
      # this is what decides whether we interrupt with a Discord alert.
      t.boolean :is_great_deal, null: false, default: false

      # ── Timestamps, mirroring Python's first_seen_at / last_seen_at ──
      # The first time our scraper ever saw this exact listing -- used to
      # tell "brand new" listings apart from ones we're just re-confirming.
      t.datetime :first_seen_at, null: false
      # The most recent time our scraper saw this listing still up. If
      # this falls too far behind "now," we treat the listing as gone.
      t.datetime :last_seen_at, null: false
      # False once a listing hasn't been seen in a while (probably sold
      # or removed) -- keeps it out of the dashboard/scoring without
      # deleting its history outright.
      t.boolean :is_active, null: false, default: true

      # Adds `created_at` and `updated_at` columns automatically -- Rails'
      # standard bookkeeping, separate from first_seen_at/last_seen_at
      # above, which track scraper-relevant history instead.
      t.timestamps
    end

    # A single listing (same listing_id on the same source) should only
    # ever exist once in this table -- this unique index is what makes
    # `find_or_initialize_by` safe to call on every scrape without ever
    # creating duplicate rows for a listing we've already saved.
    add_index :listings, [ :source, :listing_id ], unique: true
    # The dashboard sorts by score constantly, so an index here keeps
    # that query fast even once the table has thousands of rows in it.
    add_index :listings, :deal_score
    # Filtering the dashboard by make/model is a common operation, so
    # both get their own index.
    add_index :listings, :make
    add_index :listings, :model
    # `expire_stale_listings` and the dashboard both filter on this.
    add_index :listings, :is_active
  end
end
