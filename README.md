# Lettermint Elixir SDK

[![Elixir Version](https://img.shields.io/badge/Elixir-1.15%2B-4B275F?style=flat-square)](https://elixir-lang.org/)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](https://github.com/lettermint/lettermint-elixir/blob/main/LICENSE)
[![Join our Discord server](https://img.shields.io/discord/1305510095588819035?logo=discord&logoColor=eee&label=Discord&labelColor=464ce5&color=0D0E28&cacheSeconds=43200)](https://lettermint.co/r/discord)

The official Elixir SDK for the [Lettermint](https://lettermint.co) sending and team APIs.

## Requirements

- Elixir 1.15 or later and a compatible Erlang/OTP release.

## Installation

Before the first Hex release, install this package from GitHub.

Add this dependency to your application's `mix.exs`:

```elixir
{:lettermint, github: "lettermint/lettermint-elixir", branch: "main"}
```

Run `mix deps.get`. The SDK uses Req for HTTP and Jason for JSON. No application configuration is required.

## Usage

### Sending Emails

Use a project token for email operations. Use a team token for management operations.

```elixir
client = Lettermint.email(System.fetch_env!("LETTERMINT_PROJECT_TOKEN"))

{:ok, message} = Lettermint.Email.send(client, %{
  from: "Example <sender@example.com>",
  to: ["recipient@example.com"],
  subject: "Hello",
  text: "Hello from Elixir",
  metadata: %{order_id: "123"},
  tags: [%{name: "type", value: "receipt"}],
  settings: %{tls: "enforced"}
}, idempotency_key: "receipt-123")

message.message_id
message.status
```

All API calls return `{:ok, result}` or `{:error, %Lettermint.Error{}}`. Invalid local arguments raise `ArgumentError`. JSON responses use generated structs. Raw message source, HTML, and text remain unchanged strings. Ping returns a trimmed string.

### Using the Pipe Operator

```elixir
alias Lettermint.EmailBuilder, as: Email

client
|> Email.new()
|> Email.from("sender@example.com")
|> Email.to(["recipient@example.com"])
|> Email.subject("Hello")
|> Email.text("Hello from Elixir")
|> Email.send(idempotency_key: "hello-123")
```

Each builder function replaces one field and returns a new builder. Use `Email.to_map/1` to prepare a batch item.

### Batch and Scheduled Messages

```elixir
Lettermint.Email.send_batch(client, [
  %{from: "sender@example.com", to: ["a@example.com"], subject: "First", text: "Hello"},
  %{from: "sender@example.com", to: ["b@example.com"], subject: "Second", text: "Hello"}
], idempotency_key: "batch-123")

Lettermint.Email.send(client, %{
  from: "sender@example.com", to: ["recipient@example.com"],
  subject: "Scheduled", text: "Hello", scheduled_at: "tomorrow at 9am"
})

Lettermint.Messages.reschedule(client, "message-id", %{scheduled_at: "tomorrow at 10am"})
Lettermint.Messages.cancel(client, "message-id")
```

The API accepts up to 500 batch items. The request and response are bare arrays. Batch `metadata` and `headers` are string maps. Scheduling accepts an ISO 8601 timestamp or a supported English date expression. Use a time zone in absolute timestamps. The API uses UTC when no time zone is given. Reschedule and cancel accept either client type.

## Team API

Use a team API token with `Lettermint.api(...)`.

```elixir
api = Lettermint.api(System.fetch_env!("LETTERMINT_TEAM_TOKEN"))
{:ok, page} = Lettermint.Domains.list(api, query: %{"page[size]" => 25})

if page.next_cursor not in [nil, :unset] do
  Lettermint.Domains.list(api, query: %{"page[cursor]" => page.next_cursor, "page[size]" => 25})
end

Lettermint.Messages.list(api, query: %{"filter[status]" => "scheduled"})
Lettermint.Projects.retrieve(api, "project-id")
Lettermint.Routes.list(api, "project-id")
Lettermint.Stats.retrieve(api)
Lettermint.Team.retrieve(api)
```

Cursor pages have `data`, `path`, `per_page`, `next_cursor`, `next_page_url`, `prev_cursor`, and `prev_page_url`. Each item in `data` is a generated struct. The SDK makes one request per call. Pass query keys exactly as the API defines them; the SDK encodes them once.

All endpoint functions are listed in `specs/operations.json`. The modules are:

| Module | Operations |
| --- | --- |
| `Lettermint.Email` | Send, batch send, ping |
| `Lettermint.API` | Ping, blocked file types |
| `Lettermint.Domains` | List, create, retrieve, delete, DNS verification, project assignment |
| `Lettermint.Messages` | List, retrieve, events, source, HTML, text, reschedule, cancel, inbound processing |
| `Lettermint.Projects` | List, create, retrieve, update, delete, token rotation |
| `Lettermint.Routes` | List, create, retrieve, update, delete, inbound domain verification |
| `Lettermint.Stats` | Statistics |
| `Lettermint.Suppressions` | List, create, delete, removal review results |
| `Lettermint.Team` | Retrieve, update, usage, roles, members, member assignment |
| `Lettermint.Webhooks` | List, create, retrieve, update, delete, test, secret rotation, deliveries |

## Responses and Models

```elixir
payload = %Lettermint.Models.SendMailRequest{
  from: "sender@example.com", to: ["recipient@example.com"],
  subject: "Hello", text: "Hello"
}

case Lettermint.Email.send(client, payload) do
  {:ok, result} -> Lettermint.Model.to_map(result)
  {:error, %Lettermint.Error{kind: :api, status: status, body: body}} -> {status, body}
  {:error, %Lettermint.Error{kind: kind}} -> kind
end
```

Request maps accept atom or string keys. Generated fields default to `:unset`, which omits the field from JSON. An explicit `nil` sends JSON `null`. Unknown response fields remain in the struct's `extra` map with string keys. Enum values remain strings, including new values from the API. Enum modules provide `values/0`. The decoder accepts an empty PHP array as an empty map only for map fields.

## Error Handling

Error kinds are `:api`, `:transport`, and `:decode`. API errors include the HTTP status and response body. Token text is removed from error data. Client inspection does not show the token. Automatic retries and redirects are disabled. Set an idempotency key when your application can repeat a write request.

## Configuration

```elixir
client = Lettermint.email("project-token", timeout: 15_000)
Lettermint.Email.ping(client, headers: %{"x-request-id" => "trace-123"})
```

Client options: `timeout` in milliseconds, `base_url` (default `https://api.lettermint.co/v1`), and `adapter` (a module that implements `Lettermint.Adapter`). The timeout applies separately to connection setup and response receipt. Request options: `query`, `headers`, and `idempotency_key`. Request headers cannot replace authentication or HTTP routing headers. HTTPS uses the HTTP library's certificate verification.

## Webhook Verification

```elixir
Lettermint.Webhook.verify(raw_body, signature_header, webhook_secret)
```

Pass the original request body bytes before JSON decoding. The signature has the format `t=timestamp,v1=hash`. Verification returns `:ok` or `{:error, :invalid_signature}`. The default time tolerance is 300 seconds in either direction. Options `now` and `tolerance` use seconds.

## Swoosh

Swoosh has an existing [Lettermint adapter](https://swoosh.hexdocs.pm/Swoosh.Adapters.Lettermint.html). Use that adapter for Swoosh mail delivery. This SDK supplies direct sending and management API access. It does not replace or redefine the Swoosh adapter.

## Testing

```sh
mix deps.get
mix test --warnings-as-errors
```

## Development

<details>
<summary>Code generation and API contract checks</summary>


```sh
mix deps.get
python3 tools/generate.py
python3 tools/generate.py --check
python3 -m unittest discover -s tools -p 'test_*.py'
mix format --check-formatted
mix compile --warnings-as-errors
mix test --warnings-as-errors
mix hex.audit
mix hex.build
```

The generator requires Python 3 and Elixir. Both API specifications are pinned in `specs/`. It does not use files from another SDK. It generates models, endpoint functions, and the operation manifest. Do not edit `lib/lettermint/generated.ex` by hand.

Tests use stored API contracts, synthetic fixtures, and a local HTTP server. They do not call the production API.

</details>

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for release changes.

## Support

For help, join the [Lettermint Discord server](https://lettermint.co/r/discord).

## Credits

- [Bjarn Bronsveld](https://github.com/bjarn)

## License

The MIT License (MIT). See [LICENSE](https://github.com/lettermint/lettermint-elixir/blob/main/LICENSE) for details.
