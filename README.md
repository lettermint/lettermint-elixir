# Lettermint Elixir SDK

[![Hex.pm](https://img.shields.io/hexpm/v/lettermint?style=flat-square)](https://hex.pm/packages/lettermint)
[![Elixir Version](https://img.shields.io/badge/Elixir-1.15%2B-4B275F?style=flat-square)](https://elixir-lang.org/)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](https://github.com/lettermint/lettermint-elixir/blob/main/LICENSE)
[![Join our Discord server](https://img.shields.io/discord/1305510095588819035?logo=discord&logoColor=eee&label=Discord&labelColor=464ce5&color=0D0E28&cacheSeconds=43200)](https://lettermint.co/r/discord)

The official Elixir SDK for [Lettermint](https://lettermint.co): send email and manage domains, projects, routes, webhooks and more through the Team API.

Upgrading from 1.x? Read [UPGRADE.md](UPGRADE.md).

## Requirements

- Elixir 1.15 or later.
- Erlang/OTP 25 or later.

## Installation

Add `lettermint` to your dependencies in `mix.exs` and run `mix deps.get`:

```elixir
def deps do
  [
    {:lettermint, "~> 2.0"}
  ]
end
```

The SDK uses [Req](https://hex.pm/packages/req) for HTTP and [Jason](https://hex.pm/packages/jason) for JSON. It needs no application configuration.

## Quick start

Create a client with a project sending token and send an email:

```elixir
lettermint = Lettermint.new(sending_token: System.fetch_env!("LETTERMINT_PROJECT_TOKEN"))

{:ok, result} =
  Lettermint.Emails.send(lettermint, %{
    from: "Acme <hello@acme.com>",
    to: ["jane@example.com"],
    subject: "Welcome to Acme",
    html: "<p>Thanks for signing up.</p>",
    text: "Thanks for signing up."
  })

result.message_id
result.status #=> "pending"
```

## Tokens

Lettermint has two kinds of API tokens:

| Option | Token | Used by | Sent as |
| --- | --- | --- | --- |
| `:sending_token` | Project sending token (`lm_…`) | `Lettermint.Emails` and `Lettermint.EmailBuilder` | `x-lettermint-token` header |
| `:team_token` | Team API token (`lm_team_…`) | Every other module (domains, messages, projects, …) | `Authorization: Bearer` header |

Pass one or both:

```elixir
lettermint =
  Lettermint.new(
    sending_token: System.get_env("LETTERMINT_PROJECT_TOKEN"),
    team_token: System.get_env("LETTERMINT_TEAM_TOKEN")
  )
```

Each part uses its own token and never falls back to the other one. If the token a function needs is missing, it raises `Lettermint.ConfigError` that names the option (``domains.list needs :team_token``) before any request. `Lettermint.ping/2` uses the team token when it is set, otherwise the sending token. `Lettermint.Messages.reschedule/4` and `Lettermint.Messages.cancel/3` accept either token in the same way.

You can also pass a single token as a string. The SDK chooses its type by the format: `lm_team_` followed by letters and digits is a team token, and `lm_` followed by letters and digits is a sending token. Any other value, such as an SSO verification token (`lm_sso_…`), raises `Lettermint.ConfigError`; pass it with `:sending_token` or `:team_token` instead. Error messages never contain the token.

```elixir
lettermint = Lettermint.new(System.fetch_env!("LETTERMINT_TOKEN"))
# Other options go in the second argument:
lettermint = Lettermint.new(System.fetch_env!("LETTERMINT_TOKEN"), timeout: 10_000)
```

### Options

| Option | Default | Description |
| --- | --- | --- |
| `:sending_token` | | Project sending token. |
| `:team_token` | | Team API token. |
| `:base_url` | `"https://api.lettermint.co/v1"` | API base URL. |
| `:timeout` | `30_000` | Request timeout in milliseconds. It covers the whole request: connecting, the response headers and the body. |
| `:adapter` | `Lettermint.Adapter.Req` | The HTTP adapter: a module that implements `Lettermint.Adapter`, or `{module, options}`. `{Lettermint.Adapter.Req, options}` passes `options` to `Req.request/1`, for example `connect_options: [proxy: ...]` or `plug: {Req.Test, MyStub}` in tests. |

The client is an immutable struct that holds no per-request state, so create it once (for example in your application's config or a module function) and share it between processes. Its tokens are kept inside closures: `inspect/2` (also with `structs: false`), `:io_lib.format("~p", ...)`, `Jason.encode/1` and crash reports never show them.

## Results and errors

Functions that call the API return `{:ok, result}` or `{:error, error}`. Functions for endpoints that answer without a body (such as `Lettermint.Projects.ReportForwarding.delete/3`) return `:ok`. Every error is an exception struct:

| Error | When | Fields |
| --- | --- | --- |
| `Lettermint.APIError` | Any other 4xx with a JSON or empty body | `status`, `code`, `message`, `details`, `body` |
| `Lettermint.AuthenticationError` | 401 | as `APIError` |
| `Lettermint.PermissionError` | 403 | as `APIError` |
| `Lettermint.NotFoundError` | 404 | as `APIError` |
| `Lettermint.ConflictError` | 409 | as `APIError` |
| `Lettermint.ValidationError` | 422 | as `APIError`, plus `errors` (field errors) |
| `Lettermint.RateLimitError` | 429 | as `APIError`, plus `retry_after` (seconds) |
| `Lettermint.ServerError` | 5xx | as `APIError` |
| `Lettermint.TimeoutError` | No complete response within the timeout | `timeout` |
| `Lettermint.ConnectionError` | The request failed (DNS, TLS, refused, reset) | `reason` (for example a `Req.TransportError`) |
| `Lettermint.UnexpectedResponseError` | An empty or non-JSON body where JSON was expected, or an error page such as a proxy's HTML 502 | `status`, `body_excerpt` |
| `Lettermint.RedirectError` | A 3xx response. Redirects are never followed, so tokens never go elsewhere. | `status` |
| `Lettermint.ClientValidationError` | The SDK rejected the request before sending it, such as invalid tags | `field` |
| `Lettermint.WebhookVerificationError` | A webhook delivery is not genuine | `reason` |
| `Lettermint.ConfigError` | **Raised**: a missing or unrecognised token, an invalid option or ID | |

`code` and `message` come from the API's error body (`{"error": {"code", "message", "details"}}` or Laravel's `{"message", "errors"}`). Tokens are removed from error bodies. `Lettermint.Error` has guards for the families:

```elixir
import Lettermint.Error, only: [is_api_error: 1]

case Lettermint.Emails.send(lettermint, message, idempotency_key: key) do
  {:ok, result} ->
    {:ok, result}

  {:error, %Lettermint.ValidationError{errors: errors}} ->
    {:invalid, errors}

  {:error, %Lettermint.RateLimitError{retry_after: seconds}} ->
    # Retry later with the same idempotency key.
    {:retry, seconds || 1}

  {:error, %Lettermint.TimeoutError{}} ->
    # The outcome is unknown. Retry with the same idempotency key.
    {:retry, 1}

  {:error, error} when is_api_error(error) ->
    {:error, error.status, error.code}

  {:error, error} ->
    {:error, error}
end
```

The SDK never retries a request and never follows a redirect.

## Sending email

### Plain maps

`Lettermint.Emails.send/3` takes the message in the API's field names (`reply_to`, `scheduled_at`, `sandbox_result`, …), with atom or string keys, or a `Lettermint.Types.SendMailRequest` struct:

```elixir
Lettermint.Emails.send(lettermint, %{
  from: "Acme <hello@acme.com>",
  to: ["jane@example.com"],
  reply_to: ["support@acme.com"],
  subject: "Your order has shipped",
  html: html,
  metadata: %{order_id: "1234"}
})
```

### The email builder

`Lettermint.Emails.compose/2` returns an immutable builder for the pipe operator. Every function returns a new builder and leaves the one it was given unchanged, so you can keep a base builder and reuse it as a template, also across processes:

```elixir
alias Lettermint.EmailBuilder, as: Email

welcome =
  lettermint
  |> Lettermint.Emails.compose()
  |> Email.from("Acme <hello@acme.com>")
  |> Email.subject("Welcome to Acme")
  |> Email.tags([%{name: "campaign", value: "welcome"}])

welcome |> Email.to("jane@example.com") |> Email.html("<p>Hi Jane</p>") |> Email.send()
welcome |> Email.to("john@example.com") |> Email.html("<p>Hi John</p>") |> Email.send()
```

When you build an email over several steps, keep the returned builder:

```elixir
email = lettermint |> Lettermint.Emails.compose() |> Email.from("hello@acme.com") |> Email.to(user.email)
email = if user.accountant, do: Email.cc(email, user.accountant), else: email
email |> Email.subject("Your invoice") |> Email.html(invoice_html) |> Email.send()
```

| Function | Description |
| --- | --- |
| `from(builder, address)` | Sender, for example `Acme <hello@acme.com>`. |
| `to/2`, `cc/2`, `bcc/2`, `reply_to/2` | Replace the recipient list. Take one address or a list. |
| `subject(builder, text)` | Subject line. |
| `html(builder, html \| nil)`, `text(builder, text \| nil)` | Bodies. `nil` removes one. |
| `headers(builder, map)` | Custom email headers. |
| `metadata(builder, map)` | Data stored with the message, not added as headers. |
| `tags(builder, [%{name: ..., value: ...}])`, `tag(builder, name \| nil)` | Name/value tags, and the legacy single tag. |
| `route(builder, slug)` | The route to send through. |
| `scheduled_at(builder, when \| nil)` | Delivery time: a `DateTime`, ISO 8601, or English such as `"tomorrow 9am"`. |
| `settings(builder, %{track_opens: ..., track_clicks: ..., tls: ...})` | Per-email settings that override the route. |
| `sandbox_result(builder, result)` | The result a Sandbox project simulates. |
| `attach(builder, filename: ..., content: ..., content_type: ..., content_id: ...)` | Adds an attachment. |
| `send(builder, options \\ [])` | Sends a snapshot of the email. The builder can be sent again. |
| `build(builder)` | Returns the message in the API's wire format. |

`Lettermint.Emails.compose(lettermint, message)` starts a builder from an existing message.

### Batch sending

Send up to 500 emails in one request. The list may mix messages and builders:

```elixir
{:ok, results} =
  Lettermint.Emails.send_batch(lettermint, [
    %{from: "hello@acme.com", to: ["jane@example.com"], subject: "Hi Jane", text: "Hello"},
    welcome |> Email.to("john@example.com") |> Email.html("<p>Hi John</p>")
  ])
```

### Idempotency

Pass an idempotency key to make retries safe. The API processes a key once, so a retry with the same key does not send the email again. The key applies only to the call it is passed to.

```elixir
Lettermint.Emails.send(lettermint, message, idempotency_key: "order-#{order.id}-confirmation")
Email.send(builder, idempotency_key: "welcome-jane")
Lettermint.Emails.send_batch(lettermint, messages, idempotency_key: "newsletter-2026-10")
```

### Scheduling

```elixir
{:ok, result} =
  lettermint
  |> Lettermint.Emails.compose()
  |> Email.from("hello@acme.com")
  |> Email.to("jane@example.com")
  |> Email.subject("Your trial ends tomorrow")
  |> Email.text("…")
  |> Email.scheduled_at(DateTime.add(DateTime.utc_now(), 1, :day))
  |> Email.send()

if result.status == "scheduled", do: IO.puts(result.scheduled_at)

Lettermint.Messages.reschedule(lettermint, result.message_id, %{scheduled_at: "2026-10-20T09:00:00Z"})
Lettermint.Messages.cancel(lettermint, result.message_id)
```

### Sandbox

In a Sandbox project, nothing is delivered. Choose the simulated result per email:

```elixir
{:ok, result} =
  lettermint
  |> Lettermint.Emails.compose()
  |> Email.from("hello@acme.com")
  |> Email.to("jane@example.com")
  |> Email.subject("Test")
  |> Email.text("Test")
  |> Email.sandbox_result("hard_bounced")
  |> Email.send()

{result.sandbox, result.sandbox_result} #=> {true, "hard_bounced"}
```

### Tags

`tags` holds up to 20 case-sensitive name/value tags (19 when the legacy `tag` is also set). Names match `^[A-Za-z0-9_-]{1,32}$`, may not start with `__lettermint` and must be unique. Values match `^[A-Za-z0-9_-]{1,64}$`. The SDK checks this before the request: `Lettermint.Emails.send/3` returns `{:error, %Lettermint.ClientValidationError{}}`, and a builder function raises it. A rejected tag leaves the builder unchanged.

### Attachments

`content` is base64 text, as the API expects it, or `{:bytes, binary}` with the raw bytes, which the SDK base64-encodes:

```elixir
lettermint
|> Lettermint.Emails.compose()
|> Email.from("billing@acme.com")
|> Email.to("jane@example.com")
|> Email.subject("Your invoice")
|> Email.html(~s(<img src="cid:logo"> Your invoice is attached.))
|> Email.attach(filename: "invoice.pdf", content: {:bytes, File.read!("invoice.pdf")}, content_type: "application/pdf")
|> Email.attach(filename: "logo.png", content: logo_base64, content_id: "logo")
|> Email.send()
```

Plain messages take the same attachment maps in `attachments`. `Lettermint.blocked_file_types/2` lists the extensions and MIME types the API rejects.

## Team API

With a team token, the client manages domains, messages, projects, routes, statistics, suppressions, the team and webhooks:

```elixir
lettermint = Lettermint.new(team_token: System.fetch_env!("LETTERMINT_TEAM_TOKEN"))

{:ok, domain} = Lettermint.Domains.create(lettermint, %{domain: "acme.com"})
{:ok, _} = Lettermint.Domains.verify_dns_records(lettermint, domain.id)

{:ok, project} = Lettermint.Projects.create(lettermint, %{name: "Production"})
project.api_token # the new project's sending token, shown once

{:ok, stats} = Lettermint.Stats.retrieve(lettermint, %{from: "2026-10-01", to: "2026-10-31"})
{:ok, html} = Lettermint.Messages.html(lettermint, "message-id")
```

| Module | Functions |
| --- | --- |
| `Lettermint.Domains` | `list`, `iterate`, `create`, `retrieve`, `delete`, `verify_dns_records`, `verify_dns_record`, `update_projects` |
| `Lettermint.Messages` | `list`, `iterate`, `retrieve`, `events`, `iterate_events`, `source`, `html`, `text`, `reschedule`, `cancel`, `process` |
| `Lettermint.Projects` | `list`, `iterate`, `create`, `retrieve`, `update`, `delete`, `rotate_token` |
| `Lettermint.Projects.ReportForwarding` | `retrieve`, `update`, `delete`, `verify`, `resend_code` |
| `Lettermint.Routes` | `list(client, project_id)`, `iterate(client, project_id)`, `create(client, project_id, …)`, `retrieve`, `update`, `delete`, `verify_inbound_domain` |
| `Lettermint.Stats` | `retrieve` |
| `Lettermint.Suppressions` | `list`, `iterate`, `create`, `delete` |
| `Lettermint.Team` | `retrieve`, `update`, `usage`, `roles` |
| `Lettermint.Team.Members` | `list`, `iterate`, `retrieve`, `update_assignment` |
| `Lettermint.Webhooks` | `list`, `iterate`, `create`, `retrieve`, `update`, `delete`, `test`, `regenerate_secret` |
| `Lettermint.Webhooks.Deliveries` | `list(client, webhook_id)`, `iterate(client, webhook_id)`, `retrieve(client, webhook_id, delivery_id)` |
| `Lettermint` | `ping`, `analytics`, `blocked_file_types` |

Every function takes the client first and a keyword list of options last: `timeout:` (milliseconds, overrides the client's timeout) and, for `Lettermint.Emails.send/3`, `send_batch/3` and `Lettermint.Messages.process/3`, `idempotency_key:`. `Lettermint.Operations` lists every API operation with its method, path, token and types.

### Query parameters and pagination

Query parameters are maps. Bracketed names are nested maps, and the SDK sends them in the API's bracket syntax (`page[size]=30&filter[status]=verified&sort=-created_at`):

```elixir
{:ok, page} =
  Lettermint.Domains.list(lettermint, %{
    page: %{size: 30},
    filter: %{status: "verified"},
    sort: ["-created_at"]
  })

page.data # a list of %Lettermint.Types.DomainListData{}
page.next_cursor

{:ok, next} = Lettermint.Domains.list(lettermint, %{page: %{size: 30, cursor: page.next_cursor}})
```

Lists of values are joined with commas, lists of maps are indexed (`filter: %{tags: [%{name: "a", value: "b"}]}` is `filter[tags][0][name]=a&filter[tags][0][value]=b`), and booleans are sent as `1` or `0`. Each list function documents its query type, for example `t:Lettermint.Types.ListMessagesQuery.t/0`.

Every list has an `iterate` function that returns a lazy `Stream` and follows `next_cursor` until the last page:

```elixir
lettermint
|> Lettermint.Messages.iterate(%{filter: %{status: "hard_bounced"}})
|> Stream.each(&IO.puts(&1.id))
|> Stream.run()

lettermint |> Lettermint.Webhooks.Deliveries.iterate(webhook_id) |> Enum.take(50)
```

The SDK requests the next page only when the stream gets to it. A failed page request raises its error, because a stream cannot return `{:error, error}`; use `list` for tuple results.

### Cancellation

To cancel a request, run it in a process and stop that process. The request stops with it:

```elixir
task = Task.async(fn -> Lettermint.Messages.list(lettermint) end)
Task.shutdown(task, :brutal_kill)
```

## Responses

JSON responses decode into structs from `Lettermint.Types`, generated from the Lettermint API specification:

- A field the API did not send is `:unset`; JSON `null` is `nil`.
- `extra` holds response fields that this version of the SDK does not know, with string keys.
- Enums are open: a value the API adds later is kept as its string. `values/0` on an enum module (for example `Lettermint.Types.MessageStatus.values/0`) lists the values known to the SDK. Give `case` expressions a catch-all clause.
- Decoding never creates atoms from response data, and never fails on an unexpected value.
- Text endpoints (`Lettermint.Messages.source/3`, `html/3`, `text/3` and `ping`) return strings.

`Lettermint.Types.to_map/1` turns a struct back into JSON-ready data, and `Lettermint.Types.decode/2` decodes JSON data into a type.

## Webhooks

Verify each webhook delivery before you trust it. Use the webhook's signing secret (`whsec_…`), not an API token, and pass the **raw** request body: the signature covers the exact bytes, so decoding and re-encoding the JSON breaks it.

```elixir
webhook = Lettermint.Webhook.new(System.fetch_env!("LETTERMINT_WEBHOOK_SECRET"))

case Lettermint.Webhook.verify(webhook, raw_body, headers) do
  {:ok, %Lettermint.WebhookPayload{event: event, data: data}} -> handle(event, data)
  {:error, %Lettermint.WebhookVerificationError{reason: reason}} -> reject(reason)
end
```

`verify/4` takes the raw body as a binary, and the headers as a map, a list of `{name, value}` (such as `conn.req_headers`) or a `Plug.Conn`. It requires `X-Lettermint-Signature` and `X-Lettermint-Delivery` (header names are case-insensitive), checks the HMAC-SHA256 signature with a constant-time comparison, checks that the delivery timestamp equals the signed one and is within the tolerance, and returns the payload as a `Lettermint.WebhookPayload` (`id`, `event`, `timestamp`, `data` and `extra`). Otherwise it returns `Lettermint.WebhookVerificationError` with a `reason`: `:signature_header_missing`, `:signature_header_malformed`, `:delivery_header_missing`, `:delivery_timestamp_mismatch`, `:timestamp_out_of_tolerance`, `:signature_mismatch`, `:body_invalid` or `:payload_invalid`.

### Phoenix and Plug

`Plug.Parsers` consumes the body, so keep a copy for the webhook route with a body reader:

```elixir
defmodule MyAppWeb.CacheBodyReader do
  # From the Plug.Parsers documentation: keeps every chunk of the body in conn.assigns.
  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
    conn = update_in(conn.assigns[:raw_body], &[body | &1 || []])
    {:ok, body, conn}
  end
end

# endpoint.ex
plug Plug.Parsers,
  parsers: [:json],
  pass: ["*/*"],
  json_decoder: Jason,
  body_reader: {MyAppWeb.CacheBodyReader, :read_body, []}
```

```elixir
defmodule MyAppWeb.LettermintWebhookController do
  use MyAppWeb, :controller

  def create(conn, _params) do
    raw_body = conn.assigns[:raw_body] |> Enum.reverse() |> IO.iodata_to_binary()
    webhook = Lettermint.Webhook.new(Application.fetch_env!(:my_app, :lettermint_webhook_secret))

    case Lettermint.Webhook.verify(webhook, raw_body, conn) do
      {:ok, payload} ->
        # Handle payload.event and payload.data here.
        send_resp(conn, 204, "")

      {:error, %Lettermint.WebhookVerificationError{}} ->
        send_resp(conn, 400, "Invalid signature")
    end
  end
end
```

### Options and lower-level verification

The default tolerance is 300 seconds in either direction. Change it with `Lettermint.Webhook.new(secret, tolerance: 60)`. `0` accepts only the current second; it does not disable the check. A valid signature does not prevent a repeated delivery within the tolerance, so track `payload.id` if you must not process an event twice.

If the headers are not at hand, call `Lettermint.Webhook.verify_signature(webhook, raw_body, signature_header, timestamp: delivery_header)`.

An empty secret or a negative tolerance raises `Lettermint.ConfigError`. `inspect/1` and `Jason.encode/1` of a verifier show only its tolerance.

## Swoosh

Swoosh has its own [Lettermint adapter](https://hexdocs.pm/swoosh/Swoosh.Adapters.Lettermint.html). Use it for Swoosh mail delivery. This SDK gives direct access to the sending and Team APIs; it does not replace the Swoosh adapter.

## Development

```sh
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix test --warnings-as-errors
mix docs --warnings-as-errors
```

`lib/lettermint/generated/` is generated by the private [SDK generator](https://github.com/lettermint/sdk-generator). Do not edit it by hand. With a checkout of the generator, `scripts/generate.sh` regenerates the files and `scripts/generate.sh --check` verifies them; set `LETTERMINT_SDK_GENERATOR` to the checkout (default `../sdk-generator`). Without the generator, as in CI, `--check` only verifies the generated headers.

The tests never call the Lettermint API: they use a test adapter and local sockets.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for release changes.

## Support

For help, join the [Lettermint Discord server](https://lettermint.co/r/discord).

## Credits

- [Bjarn Bronsveld](https://github.com/bjarn)

## License

The MIT License (MIT). See [LICENSE](https://github.com/lettermint/lettermint-elixir/blob/main/LICENSE) for details.
