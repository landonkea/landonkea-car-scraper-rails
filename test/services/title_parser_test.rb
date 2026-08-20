require "test_helper"

# TitleParser is a straight port of Python's product_types/cars.py --
# these tests exercise the regex extraction and keyword-filtering rules
# directly with realistic listing titles, no scraper or database
# involved.
class TitleParserTest < ActiveSupport::TestCase
  test "parse extracts year, make, model, mileage, transmission, doors, title status, and fuel type" do
    parsed = TitleParser.parse("2018 Honda Fit LX Clean Title 45,000 mi Automatic Sedan Hybrid")

    assert_equal 2018, parsed[:year]
    assert_equal "Honda", parsed[:make]
    # TitleParser.extract_model works against the lowercased title (a
    # quirk carried over faithfully from Python's `_extract_model`,
    # which has the exact same behavior), so the model comes back
    # lowercase even though the make is properly capitalized.
    assert_equal "fit lx", parsed[:model]
    assert_equal 45_000, parsed[:mileage]
    assert_equal "Automatic", parsed[:transmission]
    assert_equal 4, parsed[:doors]
    assert_equal "Clean", parsed[:title_status]
    assert_equal "Hybrid", parsed[:fuel_type]
  end

  test "parse handles the 'Nk miles' mileage shorthand" do
    parsed = TitleParser.parse("2017 Kia Rio 62k miles Automatic")
    assert_equal 62_000, parsed[:mileage]
  end

  test "parse returns nil fields it cannot find rather than raising" do
    parsed = TitleParser.parse("Great little car for sale")
    assert_nil parsed[:year]
    assert_nil parsed[:make]
    assert_nil parsed[:mileage]
  end

  test "relevant? rejects parts-only and accessory listings" do
    assert_not TitleParser.relevant?("2018 Honda Fit engine only for parts")
    assert_not TitleParser.relevant?("Honda Fit floor mats", nil)
  end

  test "relevant? rejects cars that do not run" do
    assert_not TitleParser.relevant?("2015 Toyota Yaris, does not run, needs engine")
  end

  test "relevant? rejects salvage and rebuilt titles" do
    assert_not TitleParser.relevant?("2019 Kia Rio salvage title")
    assert_not TitleParser.relevant?("2019 Kia Rio rebuilt title")
  end

  test "relevant? rejects SUVs, trucks, and known non-compact models" do
    assert_not TitleParser.relevant?("2018 Honda CR-V AWD SUV")
    assert_not TitleParser.relevant?("2018 Toyota Tacoma 4x4 pickup")
  end

  test "relevant? accepts an ordinary compact car listing" do
    assert TitleParser.relevant?("2018 Honda Fit LX Clean Title Automatic")
  end

  test "matches_search? rejects a listing older than the minimum year" do
    parsed = TitleParser.parse("2012 Honda Fit Automatic")
    assert_not TitleParser.matches_search?(parsed, expected_make: "Honda")
  end

  test "matches_search? rejects manual transmissions" do
    parsed = TitleParser.parse("2019 Honda Fit 6 speed manual")
    assert_not TitleParser.matches_search?(parsed, expected_make: "Honda")
  end

  test "matches_search? rejects mileage over the maximum" do
    parsed = TitleParser.parse("2019 Honda Fit 180,000 miles Automatic")
    assert_not TitleParser.matches_search?(parsed, expected_make: "Honda")
  end

  test "matches_search? rejects a listing whose parsed make does not match the expected make" do
    parsed = TitleParser.parse("2019 Toyota Yaris Automatic")
    assert_not TitleParser.matches_search?(parsed, expected_make: "Honda")
  end

  test "matches_search? accepts a listing that clears every filter" do
    parsed = TitleParser.parse("2019 Honda Fit Clean Title 45,000 mi Automatic Sedan")
    assert TitleParser.matches_search?(parsed, expected_make: "Honda")
  end

  test "matches_search? does not reject fields it could not determine" do
    # A bare title with no doors/mileage/transmission mentioned should
    # not be rejected just because those fields came back nil.
    parsed = TitleParser.parse("2019 Honda Fit")
    assert TitleParser.matches_search?(parsed, expected_make: "Honda")
  end
end
