using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.AspNetCore.Mvc.Testing;

namespace ApiDotnet.Tests;

public class EndpointTests(WebApplicationFactory<Program> factory)
    : IClassFixture<WebApplicationFactory<Program>>
{
    private readonly HttpClient _client = factory.CreateClient();

    [Fact]
    public async Task Healthz_ReturnsOk()
    {
        var response = await _client.GetAsync("/healthz");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);

        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal("ok", body.GetProperty("status").GetString());
    }

    [Fact]
    public async Task Readyz_ReportsTheEnvironment()
    {
        var response = await _client.GetAsync("/readyz");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);

        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal("ready", body.GetProperty("status").GetString());
        Assert.False(string.IsNullOrWhiteSpace(body.GetProperty("environment").GetString()));
    }

    [Fact]
    public async Task ListOrders_ReturnsTheFixtureEnvelope()
    {
        var response = await _client.GetAsync("/api/v1/orders");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);

        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal(1, body.GetProperty("count").GetInt32());
        Assert.Equal("ord-1a2b3c4d", body.GetProperty("items")[0].GetProperty("id").GetString());
    }

    [Fact]
    public async Task CreateOrder_ComputesTheTotal()
    {
        var payload = new
        {
            customer_id = "cust-0000abcd",
            items = new[] { new { sku = "WIDGET-01", quantity = 2, unit_price_cents = 500 } },
        };

        var response = await _client.PostAsJsonAsync("/api/v1/orders", payload);
        Assert.Equal(HttpStatusCode.Created, response.StatusCode);

        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal(1000, body.GetProperty("total_cents").GetInt32());
        Assert.StartsWith("ord-", body.GetProperty("id").GetString());
    }

    [Theory]
    [InlineData("nope", 1, 100)]
    [InlineData("cust-0000abcd", 0, 100)]
    [InlineData("cust-0000abcd", 1, -1)]
    public async Task CreateOrder_RejectsInvalidPayloads(string customerId, int quantity, int price)
    {
        var payload = new
        {
            customer_id = customerId,
            items = new[] { new { sku = "WIDGET-01", quantity, unit_price_cents = price } },
        };

        var response = await _client.PostAsJsonAsync("/api/v1/orders", payload);
        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    [Fact]
    public async Task CreateOrder_RejectsAnEmptyItemList()
    {
        var payload = new { customer_id = "cust-0000abcd", items = Array.Empty<object>() };
        var response = await _client.PostAsJsonAsync("/api/v1/orders", payload);
        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }
}
