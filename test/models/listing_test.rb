require "test_helper"

class ListingTest < ActiveSupport::TestCase
  test "requires source, listing_id, title, price_usd, and url" do
    listing = Listing.new
    assert_not listing.valid?
    assert_includes listing.errors.attribute_names, :source
    assert_includes listing.errors.attribute_names, :listing_id
    assert_includes listing.errors.attribute_names, :title
    assert_includes listing.errors.attribute_names, :price_usd
    assert_includes listing.errors.attribute_names, :url
  end

  test "active scope only includes listings still marked active" do
    assert_includes Listing.active, listings(:great_fit)
    assert_not_includes Listing.active, listings(:sold_spark)
  end

  test "great_deals scope only includes listings flagged as great deals" do
    assert_includes Listing.great_deals, listings(:great_fit)
    assert_not_includes Listing.great_deals, listings(:mediocre_versa)
  end

  test "best_first orders by deal_score descending" do
    ordered = Listing.where(id: [ listings(:great_fit).id, listings(:mediocre_versa).id ]).best_first
    assert_equal [ listings(:great_fit), listings(:mediocre_versa) ], ordered.to_a
  end

  test "spec_bonus rewards a clean title, low mileage, a recent year, a reliable make, and hybrid fuel" do
    listing = Listing.new(title_status: "Clean", mileage: 40_000, year: 2021, make: "Honda", fuel_type: "Hybrid")
    # 15 (clean) + 15 (under 50k) + 10 (2020+) + 5 (reliable make) + 3 (hybrid) = 48
    assert_in_delta 48.0, listing.spec_bonus, 0.01
  end

  test "spec_bonus gives nothing for an unknown make, high mileage, and an old year" do
    listing = Listing.new(title_status: "Salvage", mileage: 145_000, year: 2015, make: "Ram", fuel_type: "Gas")
    assert_in_delta 0.0, listing.spec_bonus, 0.01
  end

  test "condition_bonus scores excellent-sounding condition text higher than merely good" do
    excellent = Listing.new(condition: "Excellent condition")
    good = Listing.new(condition: "Good used car")
    none = Listing.new(condition: nil)

    assert_in_delta 5.0, excellent.condition_bonus, 0.01
    assert_in_delta 1.0, good.condition_bonus, 0.01
    assert_in_delta 0.0, none.condition_bonus, 0.01
  end

  test "seller_bonus rewards private-party sellers over dealers" do
    private_party = Listing.new(seller_type: "private_party")
    dealer = Listing.new(seller_type: "dealer")

    assert_in_delta 5.0, private_party.seller_bonus, 0.01
    assert_in_delta 0.0, dealer.seller_bonus, 0.01
  end
end
