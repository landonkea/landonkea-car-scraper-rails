# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_20_093639) do
  create_table "listings", force: :cascade do |t|
    t.string "condition"
    t.datetime "created_at", null: false
    t.float "deal_score"
    t.integer "doors"
    t.datetime "first_seen_at", null: false
    t.string "fuel_type"
    t.boolean "is_active", default: true, null: false
    t.boolean "is_great_deal", default: false, null: false
    t.datetime "last_seen_at", null: false
    t.string "listing_id", null: false
    t.string "location"
    t.string "make"
    t.integer "mileage"
    t.string "model"
    t.float "price_usd", null: false
    t.string "seller_type"
    t.string "source", null: false
    t.string "title", null: false
    t.string "title_status"
    t.string "transmission"
    t.datetime "updated_at", null: false
    t.text "url", null: false
    t.integer "year"
    t.index ["deal_score"], name: "index_listings_on_deal_score"
    t.index ["is_active"], name: "index_listings_on_is_active"
    t.index ["make"], name: "index_listings_on_make"
    t.index ["model"], name: "index_listings_on_model"
    t.index ["source", "listing_id"], name: "index_listings_on_source_and_listing_id", unique: true
  end
end
