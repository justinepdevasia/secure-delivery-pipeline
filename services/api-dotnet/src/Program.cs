using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.AspNetCore.Http.Json;

// A second runtime exists here for one reason: to prove the pipeline handles more
// than one. The application logic is deliberately trivial.

var builder = WebApplication.CreateBuilder(args);

builder.Logging.ClearProviders();
builder.Logging.AddJsonConsole(options => options.IncludeScopes = true);

builder.Services.Configure<JsonOptions>(options =>
{
    options.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower;
    options.SerializerOptions.DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull;
});

var app = builder.Build();

var environment = Environment.GetEnvironmentVariable("APP_ENV") ?? "local";

app.MapGet("/healthz", () => Results.Ok(new StatusResponse("ok")));

app.MapGet("/readyz", () => Results.Ok(new ReadyResponse("ready", environment)));

app.MapGet("/api/v1/orders", () => Results.Ok(new OrderList(Orders.Fixtures, Orders.Fixtures.Count)));

app.MapPost("/api/v1/orders", (OrderCreate payload) =>
{
    var problems = Orders.Validate(payload);
    if (problems.Count > 0)
    {
        return Results.ValidationProblem(problems);
    }

    var order = new Order(
        $"ord-{Guid.NewGuid().ToString("N")[..8]}",
        payload.CustomerId,
        "pending",
        payload.Items,
        payload.Items.Sum(item => item.Quantity * item.UnitPriceCents));

    return Results.Created($"/api/v1/orders/{order.Id}", order);
});

app.Run();

public record StatusResponse(string Status);

public record ReadyResponse(string Status, string Environment);

public record OrderItem(string Sku, int Quantity, int UnitPriceCents);

public record OrderCreate(string CustomerId, IReadOnlyList<OrderItem> Items);

public record Order(
    string Id,
    string CustomerId,
    string Status,
    IReadOnlyList<OrderItem> Items,
    int TotalCents);

public record OrderList(IReadOnlyList<Order> Items, int Count);

public static class Orders
{
    public static readonly IReadOnlyList<Order> Fixtures =
    [
        new("ord-1a2b3c4d", "cust-0000abcd", "shipped", [new("WIDGET-01", 2, 1250)], 2500),
    ];

    /// <summary>Rejects the same shapes the Python service rejects.</summary>
    public static Dictionary<string, string[]> Validate(OrderCreate payload)
    {
        var problems = new Dictionary<string, string[]>();

        if (!System.Text.RegularExpressions.Regex.IsMatch(
                payload.CustomerId ?? string.Empty, "^cust-[0-9a-f]{8}$"))
        {
            problems["customer_id"] = ["must match ^cust-[0-9a-f]{8}$"];
        }

        if (payload.Items is null || payload.Items.Count == 0)
        {
            problems["items"] = ["at least one item is required"];
        }
        else if (payload.Items.Any(item => item.Quantity < 1 || item.UnitPriceCents < 0))
        {
            problems["items"] = ["quantity must be >= 1 and unit_price_cents >= 0"];
        }

        return problems;
    }
}

/// <summary>Exposed so WebApplicationFactory can host the app in tests.</summary>
public partial class Program;
