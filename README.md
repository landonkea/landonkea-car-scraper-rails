# Car Scraper (Rails)

This is a Rails 8 rewrite of a Python scraper. Every 6 hours it checks
Craigslist, OfferUp, eBay, and CarGurus for cheap, small, automatic
2015-or-newer cars around Arizona (Honda Fit, Toyota Yaris, Kia Rio,
Nissan Versa, and 14 other compact/subcompact models), scores each
listing on how good a deal it is, and posts the best ones to a Discord
channel. A small web dashboard shows whatever it currently has, sorted
best-first.

Nothing here needs a person watching it. Set a Discord webhook URL once,
and from then on the app scrapes on its own schedule and pings you when
something worth looking at shows up.

## How the pieces fit together

If you've never read code before, here's what each file is actually
doing, in plain English:

- **`app/models/listing.rb`** — the definition of "a listing." One row
  in the database per car we've found, plus the shared thresholds
  (2015+, under 150k miles, automatic, 4+ doors, clean title) every
  search uses, and a few scoring helpers (`spec_bonus`, `condition_bonus`,
  `seller_bonus`) that add up points for things like low mileage, a
  reliable make, or a private-party seller.
- **`app/services/title_parser.rb`** — car listing titles are just free
  text ("2018 Honda Fit LX Clean Title 45,000 mi Automatic"), so this
  file digs the actual year/make/model/mileage/transmission/doors/title
  status/fuel type back out of that text with regular expressions. It
  also rejects listings that clearly aren't what we want — parts-only
  ads, SUVs and trucks, salvage titles, cars that don't run.
- **`app/services/price_analyzer.rb`** — turns a batch of listings (all
  for the same car search, so a fair comparison) into 0-100 deal scores
  by weighing each price against that batch's own median, then adding
  bonuses for condition, source trustworthiness, private-party sellers,
  and the specs above.
- **`app/services/scrapers/craigslist_scraper.rb`** — downloads
  Craigslist's search results as plain HTML and picks listings out of
  it. Craigslist doesn't need a real browser to read, just a normal web
  request.
- **`app/services/scrapers/offerup_scraper.rb`**,
  **`ebay_scraper.rb`**, **`cargurus_scraper.rb`** — these three sites
  either render their listings with JavaScript or actively block plain
  HTTP requests, so each of these drives an actual headless Chrome
  browser (via the `ferrum` gem) to load the page and read back what
  ends up on screen.
- **`app/services/scrapers/listing_filter.rb`** — the shared "does this
  listing actually match what we're searching for" check, used by all
  four scrapers so they can't drift apart on the rules.
- **`app/services/discord_notifier.rb`** — builds and sends the Discord
  alert for one car search's top deals.
- **`app/services/scrape_runner.rb`** — the conductor. For each of the
  18 car searches, runs all four scrapers, saves what they found,
  scores that batch, and alerts Discord if anything new or great turned
  up. Also expires listings nobody's seen in 72 hours and deletes ones
  that have been gone for 180+ days.
- **`app/jobs/scrape_listings_job.rb`** — a background job that calls
  `ScrapeRunner`. "Background" means it runs on its own, separate from
  anyone visiting the website — nobody has to sit and wait for a scrape
  across 18 searches and 4 marketplaces to finish.
- **`config/recurring.yml`** — tells Rails' job scheduler (Solid Queue)
  to run that job automatically every 6 hours. No cron job or GitHub
  Action needed; it's built into the app itself.
- **`app/controllers/listings_controller.rb`** and
  **`app/views/listings/index.html.erb`** — the dashboard page. Reads
  whatever's currently active in the database and displays it as a
  table, with dropdowns to filter by make/model/source and a checkbox
  for great deals only.
- **`db/migrate/..._create_listings.rb`** — the blueprint for the
  `listings` database table: which columns exist, what type each one is.

## Running it locally

You'll need Ruby 3.4.9 and Rails 8.1 installed (this repo assumes
`rbenv`, matching the other Rails apps in this collection).

```
bundle install
bin/rails db:prepare
bin/rails server
```

Then visit `http://localhost:3000` for the dashboard.

To actually run a scrape by hand instead of waiting for the schedule,
open a Rails console and call the runner directly:

```
bin/rails console
ScrapeRunner.call
```

For the background job scheduler (needed if you want the automatic
6-hourly run to actually fire) run:

```
bin/jobs
```

alongside the web server.

## Environment variables

Copy `.env.example` to `.env` and fill in what you need:

- **`DISCORD_WEBHOOK_URL`** — where alerts get posted. Get one from
  Discord: open your server, go to Settings → Integrations → Webhooks →
  New Webhook, then copy the URL. Leave it blank and the app still runs
  fine, it just logs listings instead of posting them anywhere.
- **`BROWSER_PATH`** — optional, only needed if the headless-browser gem
  can't find Chrome on its own. The Docker image sets this automatically.

`.env` is listed in `.gitignore` so your real webhook URL never ends up
on GitHub. `.env.example` has no real values in it, just the variable
names — that one's safe to commit.

## Running the tests

```
bin/rails test
```

This runs 60 tests covering the title-parsing/filtering logic, the deal
scoring math, all four scrapers (using fake stubbed-out web pages and
fixture JSON, no real internet requests happen during tests), the
Discord notifier, ScrapeRunner's save/dedupe/expire/prune logic, and the
dashboard page. All green as of this writing.

## Deploying / Docker

`rails new` already set up a production-ready `Dockerfile` (Rails
scaffolding, not written by hand for this project), with one addition:
it installs `chromium` inside the image specifically so the
headless-browser scrapers work once deployed. Build it with:

```
docker build -t landonkea-car-scraper-rails .
```

Without `chromium` in the image, the OfferUp/eBay/CarGurus scrapers
would silently find nothing in production — Craigslist (plain HTML, no
browser needed) would still work fine either way.

## What's different from the Python version, and why

- **Ferrum instead of Playwright.** Ferrum is the closest Ruby
  equivalent to Playwright — it drives a real headless Chrome browser
  the same way. The one thing it doesn't have is an equivalent to
  `playwright-stealth`, the anti-bot-detection layer the Python version
  paired with OfferUp, eBay, and CarGurus specifically because those
  three sites push back hardest against automation. That means this
  rewrite may get blocked by those three more often than the Python
  version was. Craigslist (plain HTML, no browser needed) is unaffected.
- **No KBB market-value comparison.** The Python version's scoring
  included up to a +15 bonus for a listing priced well below a scraped
  Kelley Blue Book estimate (`kbb.py`), built on a separate static
  price-lookup table. That table wasn't carried over, so this rewrite's
  score is based purely on how a listing compares to the other listings
  found in the same search, plus the same condition/source/spec bonuses
  the Python version also used. The comparison-to-market-value idea is
  gone; comparison-to-the-rest-of-this-batch is not.
- **One alert type instead of four.** The Python version had separate
  Discord alerts for top deals, price drops on listings already seen,
  "great deal disappeared" (scooped), and a personal watchlist. This
  rewrite keeps the one that matters most — top deals for each car
  search — and drops the other three, along with the VIN-decoding
  enrichment and the daily price-trend-chart export those other
  features depended on.
- **CarGurus's model-ID map is incomplete, same as Python's was.** The
  Python version only mapped 4 of its 18 car models to CarGurus's
  internal "entity ID" system (used to filter results server-side).
  This rewrite keeps that same, incomplete map rather than guessing at
  IDs nobody's verified — for the other 14 models, CarGurus returns
  broader results and `ListingFilter` catches wrong-make listings
  afterward instead.
- **Fewer, representative CarGurus zip codes.** The Python version hit
  every Arizona city's zip code from its config. Since CarGurus returns
  results for a wide radius around one zip, this rewrite queries three
  representative metro-area zips instead of ~30 near-duplicate ones.
- **Scheduling moved into the app.** The Python version's 6-hour run
  was config-driven (`schedule.interval_hours: 6`) but externally
  triggered. This version uses Solid Queue's own recurring-task
  scheduler (`config/recurring.yml`) instead, set to the same interval.

Everything else — the price thresholds, the deal-scoring formula
(price-vs-median, condition, source reliability, seller type, spec
bonuses, the suspicious-price cap), the title-parsing rules, the
rejected-body-type and rejected-model lists, and the Discord embed
format and colors — is a direct port with no logic changes.
