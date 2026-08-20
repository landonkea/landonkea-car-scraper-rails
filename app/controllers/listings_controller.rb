# Serves the dashboard page -- the one screen a person actually looks at
# to see what the scraper found. Nothing here writes to the database;
# this controller only ever reads and displays what ScrapeListingsJob
# already saved.
class ListingsController < ApplicationController
  # `index` handles GET /listings (and GET / via the root route) --
  # Rails automatically renders app/views/listings/index.html.erb after
  # this method runs, using whatever instance variables (@listings,
  # @makes, etc.) got set below.
  def index
    # Start from every listing our last scrape still confirmed is
    # active, best-scored first -- `active` and `best_first` are scopes
    # defined on the model so this line stays readable instead of
    # spelling out the WHERE/ORDER BY clauses here too.
    scope = Listing.active.best_first

    # `params[:make]` is whatever the "?make=Honda" query string holds,
    # if anything -- lets someone filter the dashboard down to just one
    # manufacturer via the dropdown in the view.
    scope = scope.where(make: params[:make]) if params[:make].present?

    # Same idea for the model dropdown ("?model=Fit").
    scope = scope.where(model: params[:model]) if params[:model].present?

    # Same idea for the source dropdown ("?source=craigslist").
    scope = scope.where(source: params[:source]) if params[:source].present?

    # A "great deals only" checkbox in the view sends `great=1`; only
    # apply that filter when the box was actually checked, so the
    # default view still shows everything.
    scope = scope.great_deals if params[:great].present?

    # `@listings` is what the view loops over to render each row of the
    # dashboard table.
    @listings = scope

    # These build the dropdown option lists straight from whatever's
    # actually in the (active) database right now, rather than a
    # hardcoded list, so they stay accurate as new makes/models/sources
    # show up.
    @makes = Listing.active.distinct.pluck(:make).compact.sort
    @models = Listing.active.distinct.pluck(:model).compact.sort
    @sources = Listing.active.distinct.pluck(:source).compact.sort

    # A short stats line at the top of the page, mirroring the summary
    # Python's main.py printed to the terminal after every run.
    @total_count = Listing.active.count
    @great_deal_count = Listing.active.great_deals.count
  end
end
