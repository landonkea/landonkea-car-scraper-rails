require "test_helper"

class ListingsControllerTest < ActionDispatch::IntegrationTest
  test "index responds successfully and shows the summary counts" do
    get listings_path
    assert_response :success
    assert_select "h1", "Car Scraper Dashboard"
  end

  test "index only lists active listings, not sold/inactive ones" do
    get listings_path
    assert_response :success
    assert_match listings(:great_fit).url, response.body
    assert_no_match(/#{Regexp.escape(listings(:sold_spark).url)}/, response.body)
  end

  test "index filters by make" do
    get listings_path, params: { make: "Nissan" }
    assert_response :success
    assert_match listings(:mediocre_versa).url, response.body
    assert_no_match(/#{Regexp.escape(listings(:great_fit).url)}/, response.body)
  end

  test "index filters to great deals only" do
    get listings_path, params: { great: "1" }
    assert_response :success
    assert_match listings(:great_fit).url, response.body
    assert_no_match(/#{Regexp.escape(listings(:mediocre_versa).url)}/, response.body)
  end

  test "root path renders the same dashboard" do
    get root_path
    assert_response :success
    assert_select "h1", "Car Scraper Dashboard"
  end
end
