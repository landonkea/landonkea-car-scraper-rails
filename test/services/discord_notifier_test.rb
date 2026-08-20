require "test_helper"

# DiscordNotifier is the piece responsible for actually telling a human
# about a good deal -- these tests stub Discord's webhook endpoint so we
# can check exactly what gets sent and how errors get handled, without
# posting to a real Discord channel during test runs.
class DiscordNotifierTest < ActiveSupport::TestCase
  setup do
    @stats = { count: 12, min: 4_500, max: 9_800, median: 6_200 }
  end

  test "does nothing and returns false when there are no top deals" do
    ENV["DISCORD_WEBHOOK_URL"] = "https://discord.com/api/webhooks/123/abc"
    assert_not DiscordNotifier.send_alert("Honda Fit", [], @stats)
  ensure
    ENV.delete("DISCORD_WEBHOOK_URL")
  end

  test "does nothing and returns false when no webhook URL is configured" do
    # Minitest's `stub` temporarily replaces ENV.fetch for the duration
    # of this block only, so we don't have to worry about a real
    # DISCORD_WEBHOOK_URL leaking in from the test machine's environment.
    ENV.stub(:fetch, nil) do
      assert_not DiscordNotifier.send_alert("Honda Fit", [ listings(:great_fit) ], @stats)
    end
  end

  test "posts an embed with the market snapshot and one field per listing" do
    ENV["DISCORD_WEBHOOK_URL"] = "https://discord.com/api/webhooks/123/abc"

    request = stub_request(:post, "https://discord.com/api/webhooks/123/abc?wait=true")
      .with { |req|
        body = JSON.parse(req.body)
        embed = body["embeds"].first
        embed["title"] == "Honda Fit Deal Alert" &&
          embed["fields"].first["name"] == "Market Snapshot" &&
          embed["fields"].second["value"].include?(listings(:great_fit).url) &&
          embed["color"] == 0x00ff00
      }
      .to_return(status: 204)

    assert DiscordNotifier.send_alert("Honda Fit", [ listings(:great_fit) ], @stats)
    assert_requested(request)
  ensure
    ENV.delete("DISCORD_WEBHOOK_URL")
  end

  test "uses an amber color when the top deal is not a great deal" do
    ENV["DISCORD_WEBHOOK_URL"] = "https://discord.com/api/webhooks/123/abc"

    request = stub_request(:post, "https://discord.com/api/webhooks/123/abc?wait=true")
      .with { |req| JSON.parse(req.body)["embeds"].first["color"] == 0xffaa00 }
      .to_return(status: 204)

    assert DiscordNotifier.send_alert("Nissan Versa", [ listings(:mediocre_versa) ], @stats)
    assert_requested(request)
  ensure
    ENV.delete("DISCORD_WEBHOOK_URL")
  end

  test "retries once after a 429 rate-limit response" do
    ENV["DISCORD_WEBHOOK_URL"] = "https://discord.com/api/webhooks/123/abc"

    stub_request(:post, "https://discord.com/api/webhooks/123/abc?wait=true")
      .to_return(
        { status: 429, body: { retry_after: 0.01 }.to_json, headers: { "Content-Type" => "application/json" } },
        { status: 204 }
      )

    assert DiscordNotifier.send_alert("Honda Fit", [ listings(:great_fit) ], @stats)
  ensure
    ENV.delete("DISCORD_WEBHOOK_URL")
  end

  test "returns false and does not raise when Discord is unreachable" do
    ENV["DISCORD_WEBHOOK_URL"] = "https://discord.com/api/webhooks/123/abc"

    stub_request(:post, "https://discord.com/api/webhooks/123/abc?wait=true").to_timeout

    assert_not DiscordNotifier.send_alert("Honda Fit", [ listings(:great_fit) ], @stats)
  ensure
    ENV.delete("DISCORD_WEBHOOK_URL")
  end
end
