# Upgrade guide

## Upgrade from 1.x to 2.0

1.x no longer receives updates, including fixes. Upgrade to 2.0 to keep getting them.

2.0 is a new major version. It moves the Elixir SDK onto the same design as the other Lettermint SDKs: one client for both tokens, the Team API grouped by resource with the same function names in every language, typed errors for every outcome, and types generated from the current API specification. The 1.x strengths stay: clients and builders are immutable, the builder works with the pipe operator, the idempotency key is a per-call option, redirects and retries are off, and decoding never creates atoms.

### Highlights

- One client: `Lettermint.new(sending_token: ..., team_token: ...)`, or `Lettermint.new(token)`. It replaces `Lettermint.email(token, opts)` and `Lettermint.api(token, opts)`.
- Each part uses its own token: `Lettermint.Emails` uses the sending token, the Team API the team token. The SDK never falls back to the other token; a missing token raises `Lettermint.ConfigError` that names the option.
- The Team API uses the layout of the other SDKs: `Lettermint.Projects.ReportForwarding`, `Lettermint.Team.Members` and `Lettermint.Webhooks.Deliveries` are their own modules, and every list has an `iterate` function that returns a `Stream`.
- Query parameters are nested maps (`%{page: %{size: 30}}`) instead of bracketed string keys.
- Errors are exception structs per kind (`Lettermint.NotFoundError`, `Lettermint.RateLimitError`, `Lettermint.TimeoutError`, …) instead of one `%Lettermint.Error{kind: ...}`. Network errors keep their reason (1.x reported only `:connection_failed`).
- The timeout covers the whole request, including the body.
- An empty 2xx body where JSON is expected is an error (1.x returned `{:ok, nil}`). A request body that cannot be encoded as JSON is an error (1.x raised `Jason.EncodeError`).
- Webhook verification takes the request headers, requires the `X-Lettermint-Delivery` header and returns the decoded payload.
- Tokens are kept inside closures, so they no longer show up in `inspect(client, structs: false)`, `:io_lib.format("~p", ...)` or crash reports.
- Types are generated from the current API specification and use its names, under `Lettermint.Types` (see [Type names](#type-names)).
- Requires Erlang/OTP 25 or later (for `:crypto.hash_equals/2`). Elixir 1.15+ as before.

### Requirements

- Elixir 1.15 or later.
- Erlang/OTP 25 or later.

### Upgrade with a coding agent

You can let a coding agent (Claude Code, Codex, Cursor, Copilot, …) do the upgrade. Copy this instruction into the agent from your project's root, then review its changes:

````text
Upgrade this project from the `lettermint` Elixir SDK 1.x to 2.0.

1. Change the dependency in mix.exs to `{:lettermint, "~> 2.0"}` and run `mix deps.update lettermint`. 2.0 needs Elixir 1.15+ and Erlang/OTP 25+: check `.tool-versions`, `mix.exs`, CI workflows and Dockerfiles, and report anything older.
2. Read the upgrade guide before changing code: `deps/lettermint/UPGRADE.md`, or https://github.com/lettermint/lettermint-elixir/blob/main/UPGRADE.md. Treat it as the source of truth and don't guess APIs; when unsure, read the source in `deps/lettermint/lib/` or the docs on HexDocs.
3. Find every use of the SDK: `Lettermint.email(`, `Lettermint.api(`, `Lettermint.Email.`, `Lettermint.API.`, `Lettermint.EmailBuilder`, `Lettermint.MessageTag`, `Lettermint.Model.`, `Lettermint.Models.`, `%Lettermint.Error{`, `Lettermint.Webhook.verify(`, the 1.x Team API modules (`Lettermint.Domains`, `Lettermint.Messages`, `Lettermint.Projects`, `Lettermint.Routes`, `Lettermint.Stats`, `Lettermint.Suppressions`, `Lettermint.Team`, `Lettermint.Webhooks`), `query:` and `headers:` request options, `Lettermint.Adapter` implementations, and the 1.x type names from the guide's type-name table.
4. Rewrite each use following the guide's before/after examples:
   - Create one client with `Lettermint.new(sending_token: ...)`, adding `team_token:` only where the Team API is used. Keep the project's existing environment variable names and config.
   - Keep the builder pipelines, but start them with `Lettermint.Emails.compose(client)` instead of `EmailBuilder.new(client)`. Replace `attachments/2` with `attach/2` and `to_map/1` with `build/1`.
   - Keep idempotency keys as the `idempotency_key:` option of `send`/`send_batch`.
   - Team API: pass query parameters as nested maps in the argument before the options (`Lettermint.Domains.list(client, %{page: %{size: 10}})`), not as `query:` with bracketed keys, and use the renamed functions from the guide.
   - Errors: match on the 2.0 exception structs (`%Lettermint.NotFoundError{}`, `%Lettermint.ValidationError{}`, …) or use the guards in `Lettermint.Error`, instead of `%Lettermint.Error{kind: ...}`.
   - Webhooks: `Lettermint.Webhook.new(secret) |> Lettermint.Webhook.verify(raw_body, conn.req_headers)`. Keep passing the raw request body, keep the secret's `whsec_` prefix, and make sure the `X-Lettermint-Signature` and `X-Lettermint-Delivery` headers reach the handler.
   - Rename `Lettermint.Models.*` types to `Lettermint.Types.*` using the guide's type-name table, and `Lettermint.Model.to_map/from_map` to `Lettermint.Types.to_map/decode`.
5. Run `mix format`, `mix compile --warnings-as-errors` and `mix test`, and fix every error. Don't send real email or call the live API while testing.
6. Finish with a summary: the files you changed, anything you could not migrate with certainty, and behaviour changes I should review.

Never print, log or commit API tokens or webhook secrets.
````

### Create the client

`Lettermint.email(token, opts)` and `Lettermint.api(token, opts)` are removed. One client holds both tokens.

```elixir
# 1.x
email = Lettermint.email(System.fetch_env!("LETTERMINT_PROJECT_TOKEN"), timeout: 10_000)
api = Lettermint.api(System.fetch_env!("LETTERMINT_TEAM_TOKEN"))

# 2.0
lettermint =
  Lettermint.new(
    sending_token: System.get_env("LETTERMINT_PROJECT_TOKEN"), # for Lettermint.Emails
    team_token: System.get_env("LETTERMINT_TEAM_TOKEN"),       # for the Team API
    timeout: 10_000
  )
```

Pass one token or both. With only one token, calling a function that needs the other raises `Lettermint.ConfigError` (for example ``domains.list needs :team_token``) before any request. 1.x raised `ArgumentError` ("Wrong client for this API operation").

You can also pass a token string. The SDK chooses the token type by its format:

```elixir
Lettermint.new("lm_team_...")                    # team token
Lettermint.new("lm_...")                         # project sending token
Lettermint.new(token, timeout: 10_000)           # with options
```

Any other format (SSO tokens, an empty string) raises `Lettermint.ConfigError`. Use `sending_token:` or `team_token:` for those.

The `:base_url`, `:timeout` and `:adapter` options work as before, with these changes:

- Invalid options raise `Lettermint.ConfigError` instead of `ArgumentError`.
- `:timeout` now covers the whole request. In 1.x it applied separately to connecting and to receiving.
- `:adapter` may be `{module, options}`. The `Lettermint.Adapter` callback changed; see [Adapters](#adapters).

### Send an email

```elixir
# 1.x
client = Lettermint.email(token)

client
|> Lettermint.EmailBuilder.new()
|> Lettermint.EmailBuilder.from("Acme <hello@acme.com>")
|> Lettermint.EmailBuilder.to(["jane@example.com"])
|> Lettermint.EmailBuilder.subject("Welcome")
|> Lettermint.EmailBuilder.html("<p>Hi Jane</p>")
|> Lettermint.EmailBuilder.send(idempotency_key: "welcome-jane")

Lettermint.Email.send(client, %{from: "Acme <hello@acme.com>", to: ["jane@example.com"], subject: "Welcome"})

# 2.0
alias Lettermint.EmailBuilder, as: Email

lettermint
|> Lettermint.Emails.compose()
|> Email.from("Acme <hello@acme.com>")
|> Email.to("jane@example.com")
|> Email.subject("Welcome")
|> Email.html("<p>Hi Jane</p>")
|> Email.send(idempotency_key: "welcome-jane")

Lettermint.Emails.send(lettermint, %{from: "Acme <hello@acme.com>", to: ["jane@example.com"], subject: "Welcome"})
```

#### Changed builder functions

| 1.x | 2.0 |
| --- | --- |
| `EmailBuilder.new(client)` | `Lettermint.Emails.compose(client)` or `compose(client, message)`; raises `Lettermint.ConfigError` without a sending token |
| `attachments(builder, [%{filename:, content:, content_type:}])` | `attach(builder, filename: ..., content: ..., content_type: ..., content_id: ...)`, once per attachment; `content` may also be `{:bytes, binary}` |
| `to_map(builder)` | `build(builder)`; returns string keys and base64-encodes `{:bytes, binary}` content |
| `to/2`, `cc/2`, `bcc/2`, `reply_to/2` took any value | Take one address or a list of addresses |
| `html(builder, nil)` and the other setters stored `nil` (sent as JSON `null`) | `html/2`, `text/2`, `tag/2` and `scheduled_at/2` with `nil` remove the field |
| `scheduled_at(builder, string)` | `scheduled_at(builder, string \| DateTime.t())` |
| `tags/2` and `tag/2` raised `ArgumentError` | Raise `Lettermint.ClientValidationError` (with `field`); the builder you passed stays valid |
| — | `sandbox_result/2` |
| `send(builder, opts)` | `send(builder, opts)`, unchanged: `idempotency_key:` and now `timeout:` |

Unchanged: `from/2`, `subject/2`, `text/2`, `route/2`, `headers/2`, `metadata/2`, `settings/2`, `tag/2`, `tags/2`. Every function still returns a new builder.

`inspect(builder)` now shows the message (`#Lettermint.EmailBuilder<%{"from" => ...}>`) and never the client's tokens. 1.x showed nothing.

#### Plain messages

`Lettermint.Email.send/3` is now `Lettermint.Emails.send/3`. Messages are still maps in the API's field names with atom or string keys, or a struct (`%Lettermint.Types.SendMailRequest{}`, was `%Lettermint.Models.SendMailRequest{}`). Changes:

- Invalid tags or attachments return `{:error, %Lettermint.ClientValidationError{}}` before any request. 1.x sent them to the API.
- A body that cannot be encoded as JSON (invalid UTF-8, a PID, a tuple) returns `{:error, %Lettermint.ClientValidationError{field: "body"}}`. 1.x raised.
- Attachment `content` is base64 text as before, or `{:bytes, binary}`, which the SDK encodes.
- `Lettermint.MessageTag.new!/2` is removed. Pass `%{name: ..., value: ...}` maps or `%Lettermint.Types.MessageTagInput{}` structs; the SDK validates them on send.

### Batch sending and ping

```elixir
# 1.x
Lettermint.Email.send_batch(client, [message1, message2], idempotency_key: "batch-1")
Lettermint.Email.ping(client)
Lettermint.API.ping(api)

# 2.0
Lettermint.Emails.send_batch(lettermint, [message1, message2], idempotency_key: "batch-1")
Lettermint.Emails.send_batch(lettermint, [builder1, builder2]) # builders work too
Lettermint.Emails.ping(lettermint) # sending token
Lettermint.ping(lettermint)        # team token if configured, otherwise the sending token
```

`send_batch/3` returns `{:ok, [%Lettermint.Types.SendMailResponse{}]}` (was `[%Lettermint.Models.SendBatchEmailResponseItem{}]`).

### Team API

The modules keep their names, but take the one client, and the nested resources have their own modules. Query parameters move from the `query:` option to an argument before the options, as nested maps. Every list also has an `iterate` function that returns a `Stream`.

```elixir
# 1.x
api = Lettermint.api(token)
{:ok, page} = Lettermint.Domains.list(api, query: %{"page[size]" => 10, "filter[status]" => "verified"})

# 2.0
{:ok, page} = Lettermint.Domains.list(lettermint, %{page: %{size: 10}, filter: %{status: "verified"}})

lettermint
|> Lettermint.Domains.iterate(%{filter: %{status: "verified"}})
|> Enum.each(&IO.puts(&1.domain))
```

| 1.x (`api = Lettermint.api(token)`) | 2.0 (`lettermint = Lettermint.new(team_token: token)`) |
| --- | --- |
| `Lettermint.API.ping(api)` | `Lettermint.ping(lettermint)` |
| `Lettermint.API.blocked_file_types(api)` | `Lettermint.blocked_file_types(lettermint)` |
| `Lettermint.API.analytics(api, payload)` | `Lettermint.analytics(lettermint, query)` |
| `Lettermint.Domains.list(api, query: params)` | `Lettermint.Domains.list(lettermint, query)`, `Lettermint.Domains.iterate(lettermint, query)` |
| `Lettermint.Domains.create(api, payload)` | `Lettermint.Domains.create(lettermint, payload)` |
| `Lettermint.Domains.retrieve(api, id)` | `Lettermint.Domains.retrieve(lettermint, id, query \\ %{})` (`%{include: ["dnsRecords"]}`) |
| `Lettermint.Domains.delete(api, id)` | `Lettermint.Domains.delete(lettermint, id)` |
| `Lettermint.Domains.verify_dns_records(api, id)` | `Lettermint.Domains.verify_dns_records(lettermint, id)` |
| `Lettermint.Domains.verify_dns_record(api, id, record_id)` | `Lettermint.Domains.verify_dns_record(lettermint, id, record_id)` |
| `Lettermint.Domains.update_projects(api, id, payload)` | `Lettermint.Domains.update_projects(lettermint, id, payload)` |
| `Lettermint.Messages.list(api, query: params)` | `Lettermint.Messages.list(lettermint, query)`, `Lettermint.Messages.iterate(lettermint, query)` |
| `Lettermint.Messages.retrieve(api, id)` | `Lettermint.Messages.retrieve(lettermint, id)` |
| `Lettermint.Messages.events(api, id, query: params)` | `Lettermint.Messages.events(lettermint, id, query)`, `Lettermint.Messages.iterate_events(lettermint, id, query)` |
| `Lettermint.Messages.source(api, id)` / `html` / `text` | unchanged names: `Lettermint.Messages.source(lettermint, id)` / `html` / `text` |
| `Lettermint.Messages.reschedule(client, id, payload)` | `Lettermint.Messages.reschedule(lettermint, id, payload)` |
| `Lettermint.Messages.cancel(client, id)` | `Lettermint.Messages.cancel(lettermint, id)` |
| `Lettermint.Messages.process(api, id, opts)` | `Lettermint.Messages.process(lettermint, id, idempotency_key: ...)` |
| `Lettermint.Projects.list(api, query: params)` | `Lettermint.Projects.list(lettermint, query)`, `Lettermint.Projects.iterate(lettermint, query)` |
| `Lettermint.Projects.create(api, payload)` | `Lettermint.Projects.create(lettermint, payload)` |
| `Lettermint.Projects.retrieve(api, id)` | `Lettermint.Projects.retrieve(lettermint, id, query \\ %{})` |
| `Lettermint.Projects.update(api, id, payload)` | `Lettermint.Projects.update(lettermint, id, payload)` |
| `Lettermint.Projects.delete(api, id)` | `Lettermint.Projects.delete(lettermint, id)` |
| `Lettermint.Projects.rotate_token(api, id)` | `Lettermint.Projects.rotate_token(lettermint, id)` (deprecated by the API) |
| `Lettermint.Projects.retrieve_report_forwarding(api, id)` | `Lettermint.Projects.ReportForwarding.retrieve(lettermint, id)` |
| `Lettermint.Projects.update_report_forwarding(api, id, payload)` | `Lettermint.Projects.ReportForwarding.update(lettermint, id, payload)` |
| `Lettermint.Projects.delete_report_forwarding(api, id)` | `Lettermint.Projects.ReportForwarding.delete(lettermint, id)`; returns `:ok` (1.x: `{:ok, nil}`) |
| `Lettermint.Projects.verify_report_forwarding(api, id, payload)` | `Lettermint.Projects.ReportForwarding.verify(lettermint, id, payload)` |
| `Lettermint.Projects.resend_report_forwarding_code(api, id)` | `Lettermint.Projects.ReportForwarding.resend_code(lettermint, id)` |
| `Lettermint.Routes.list(api, project_id, query: params)` | `Lettermint.Routes.list(lettermint, project_id, query)`, `Lettermint.Routes.iterate(lettermint, project_id, query)` |
| `Lettermint.Routes.create(api, project_id, payload)` | `Lettermint.Routes.create(lettermint, project_id, payload)` |
| `Lettermint.Routes.retrieve(api, id)` | `Lettermint.Routes.retrieve(lettermint, id, query \\ %{})` |
| `Lettermint.Routes.update(api, id, payload)` | `Lettermint.Routes.update(lettermint, id, payload)` |
| `Lettermint.Routes.delete(api, id)` | `Lettermint.Routes.delete(lettermint, id)` |
| `Lettermint.Routes.verify_inbound_domain(api, id)` | `Lettermint.Routes.verify_inbound_domain(lettermint, id)` |
| `Lettermint.Stats.retrieve(api, query: params)` | `Lettermint.Stats.retrieve(lettermint, %{from: ..., to: ..., project_id: ..., include_machine: ...})` (the query is required) |
| `Lettermint.Suppressions.list(api, query: params)` | `Lettermint.Suppressions.list(lettermint, query)`, `Lettermint.Suppressions.iterate(lettermint, query)` |
| `Lettermint.Suppressions.create(api, payload)` | `Lettermint.Suppressions.create(lettermint, payload)` |
| `Lettermint.Suppressions.delete(api, id)` | `Lettermint.Suppressions.delete(lettermint, id)` |
| `Lettermint.Team.retrieve(api, query: params)` | `Lettermint.Team.retrieve(lettermint, query)` (`%{include: ["features"]}`) |
| `Lettermint.Team.update(api, payload)` | `Lettermint.Team.update(lettermint, payload)` |
| `Lettermint.Team.usage(api)` | `Lettermint.Team.usage(lettermint)` |
| `Lettermint.Team.roles(api)` | `Lettermint.Team.roles(lettermint)` |
| `Lettermint.Team.members(api, query: params)` | `Lettermint.Team.Members.list(lettermint, query)`, `Lettermint.Team.Members.iterate(lettermint, query)` |
| `Lettermint.Team.retrieve_member(api, user_id)` | `Lettermint.Team.Members.retrieve(lettermint, user_id)` |
| `Lettermint.Team.update_member_assignment(api, user_id, payload)` | `Lettermint.Team.Members.update_assignment(lettermint, user_id, payload)` |
| `Lettermint.Webhooks.list(api, query: params)` | `Lettermint.Webhooks.list(lettermint, query)`, `Lettermint.Webhooks.iterate(lettermint, query)` |
| `Lettermint.Webhooks.create(api, payload)` | `Lettermint.Webhooks.create(lettermint, payload)` |
| `Lettermint.Webhooks.retrieve(api, id)` | `Lettermint.Webhooks.retrieve(lettermint, id)` |
| `Lettermint.Webhooks.update(api, id, payload)` | `Lettermint.Webhooks.update(lettermint, id, payload)` |
| `Lettermint.Webhooks.delete(api, id)` | `Lettermint.Webhooks.delete(lettermint, id)` |
| `Lettermint.Webhooks.test(api, id)` | `Lettermint.Webhooks.test(lettermint, id)` |
| `Lettermint.Webhooks.regenerate_secret(api, id)` | `Lettermint.Webhooks.regenerate_secret(lettermint, id)` |
| `Lettermint.Webhooks.deliveries(api, id, query: params)` | `Lettermint.Webhooks.Deliveries.list(lettermint, id, query)`, `Lettermint.Webhooks.Deliveries.iterate(lettermint, id, query)` |
| `Lettermint.Webhooks.show_delivery(api, id, delivery_id)` | `Lettermint.Webhooks.Deliveries.retrieve(lettermint, id, delivery_id)` |

`Lettermint.Messages.reschedule/4` and `cancel/3` accept either token: the team token when configured, otherwise the sending token. This lets a sending-only client cancel the scheduled email it sent.

#### Request options

Every function takes a keyword list of options last.

| 1.x | 2.0 |
| --- | --- |
| `query: %{...}` | Removed: pass the query map as its own argument, before the options. Passing a keyword list where the query goes raises `Lettermint.ConfigError`. |
| `headers: %{...}` | Removed. |
| `idempotency_key: key` | Unchanged, on `Lettermint.Emails.send/3`, `send_batch/3`, `Lettermint.EmailBuilder.send/2` and `Lettermint.Messages.process/3` only. |
| — | `timeout: ms` overrides the client's timeout for one call. |

Unknown options raise `Lettermint.ConfigError` (1.x: `ArgumentError`).

#### Query parameters

Write bracketed names as nested maps (atom or string keys). Lists of values are joined with commas, lists of maps are indexed, and booleans are sent as `1`/`0`.

| 1.x (`query:`) | 2.0 |
| --- | --- |
| `%{"page[size]" => 30, "page[cursor]" => c}` | `%{page: %{size: 30, cursor: c}}` |
| `%{"filter[status]" => "verified"}` | `%{filter: %{status: "verified"}}` |
| `%{"sort" => "-created_at,domain"}` | `%{sort: ["-created_at", "domain"]}` |
| `%{"filter[tags][0][name]" => "a", "filter[tags][0][value]" => "b"}` | `%{filter: %{tags: [%{name: "a", value: "b"}]}}` |
| `%{"filter[enabled]" => "true"}` | `%{filter: %{enabled: true}}` |
| webhooks: `%{"cursor" => c}` | unchanged: `%{cursor: c}` (these lists use `cursor`, not `page[cursor]`) |

#### Path parameters

IDs are still URL-encoded. An empty ID, `"."` or `".."` raises `Lettermint.ConfigError` before the request, as in 1.x (which raised `ArgumentError`).

#### Lists and pagination

List responses decode into `%Lettermint.Types.CursorPage{data: [...], next_cursor: ..., ...}` (1.x had one struct per list, such as `%Lettermint.Models.DomainIndexResponse{}`, with the same fields). Read `page.next_cursor`, or use `iterate`, which follows it for you and stops on a repeated cursor. A stream raises the error of a failed page, because a stream cannot return `{:error, error}`.

### Errors

`%Lettermint.Error{kind: ..., status: ..., body: ...}` is replaced by one exception struct per kind. `Lettermint.Error` is now a module with guards (`is_lettermint_error/1`, `is_api_error/1`).

| Situation | 1.x | 2.0 |
| --- | --- | --- |
| HTTP 400 and other 4xx | `%Lettermint.Error{kind: :api, status: s, body: body}` | `%Lettermint.APIError{status, code, message, details, body}` |
| HTTP 401 | `kind: :api` | `%Lettermint.AuthenticationError{}` |
| HTTP 403 | `kind: :api` | `%Lettermint.PermissionError{}` |
| HTTP 404 | `kind: :api` | `%Lettermint.NotFoundError{}` |
| HTTP 409 | `kind: :api` | `%Lettermint.ConflictError{}` |
| HTTP 422 | `kind: :api` | `%Lettermint.ValidationError{errors: %{"field" => [...]}}` |
| HTTP 429 | `kind: :api` | `%Lettermint.RateLimitError{retry_after: seconds}` |
| HTTP 5xx | `kind: :api` | `%Lettermint.ServerError{}` |
| Redirect (3xx) | `kind: :api` with the 3xx status | `%Lettermint.RedirectError{status}` (never followed, as before) |
| HTML error page, invalid JSON | `kind: :api` with the raw body, or `kind: :decode` | `%Lettermint.UnexpectedResponseError{status, body_excerpt}` |
| Empty 2xx body where JSON is expected | `{:ok, nil}` | `%Lettermint.UnexpectedResponseError{status}` |
| Timeout | `kind: :transport` | `%Lettermint.TimeoutError{timeout}`; covers the whole request |
| Network failure | `kind: :transport` (`:connection_failed`) | `%Lettermint.ConnectionError{reason}`, with the HTTP client's reason |
| A response that does not match its type | `kind: :decode` | Decoded anyway: unexpected values are kept as decoded from JSON |
| Invalid tags or attachments | `ArgumentError` (builder) or sent to the API | `%Lettermint.ClientValidationError{field}` |
| A body that cannot be encoded as JSON | `Jason.EncodeError` raised | `%Lettermint.ClientValidationError{field: "body"}` |
| Missing or wrong token, bad option or ID | `ArgumentError` raised | `Lettermint.ConfigError` raised |

`code` comes from `{"error": {"code": ...}}` or a string `error` field. `message` is the API's message, or `"HTTP <status>"`. Every error is an exception, so you can also `raise error`.

```elixir
# 1.x
case Lettermint.Email.send(client, message) do
  {:ok, result} -> result
  {:error, %Lettermint.Error{kind: :api, status: 422, body: body}} -> {:invalid, body}
  {:error, %Lettermint.Error{kind: :api, status: 429}} -> :retry_later
  {:error, %Lettermint.Error{kind: kind}} -> {:failed, kind}
end

# 2.0
case Lettermint.Emails.send(lettermint, message) do
  {:ok, result} -> result
  {:error, %Lettermint.ValidationError{errors: errors}} -> {:invalid, errors}
  {:error, %Lettermint.RateLimitError{retry_after: seconds}} -> {:retry_later, seconds}
  {:error, error} -> {:failed, error}
end
```

The SDK does not retry requests. Pass an `idempotency_key` when you retry a send.

### Webhooks

```elixir
# 1.x
:ok = Lettermint.Webhook.verify(raw_body, signature_header, secret, tolerance: 300)

# 2.0
webhook = Lettermint.Webhook.new(secret, tolerance: 300)
{:ok, payload} = Lettermint.Webhook.verify(webhook, raw_body, conn.req_headers)
{:ok, payload} = Lettermint.Webhook.verify_signature(webhook, raw_body, signature_header, timestamp: delivery_header)
```

- The secret moves into a verifier struct, `Lettermint.Webhook.new/2`. An empty secret or a negative tolerance raises `Lettermint.ConfigError` (1.x returned `{:error, :invalid_signature}`).
- `verify/4` takes the request headers (a map, a list such as `conn.req_headers`, or a `Plug.Conn`) and **requires** both `X-Lettermint-Signature` and `X-Lettermint-Delivery`, which must equal the signed timestamp. 1.x did not read the delivery header.
- On success it returns `{:ok, %Lettermint.WebhookPayload{id, event, timestamp, data, extra}}` (1.x: `:ok`), so you no longer decode the body yourself.
- Failures return `{:error, %Lettermint.WebhookVerificationError{reason: reason}}` instead of `{:error, :invalid_signature}`. The reasons are `:signature_header_missing`, `:signature_header_malformed`, `:delivery_header_missing`, `:delivery_timestamp_mismatch`, `:timestamp_out_of_tolerance`, `:signature_mismatch`, `:body_invalid` and `:payload_invalid`.
- The `:now` option (Unix seconds) works as before, on `verify/4` and `verify_signature/4`. `:tolerance` moves to `new/2`.

### Adapters

The `Lettermint.Adapter` behaviour changed so that the SDK can read response headers (`Retry-After`, `Content-Type`):

| 1.x | 2.0 |
| --- | --- |
| `@callback request(map()) :: {:ok, status, body} \| {:error, term()}` | `@callback request(request :: map(), options :: keyword()) :: {:ok, %{status: status, headers: headers, body: body}} \| {:error, reason}` |
| `request.headers` was a map | `request.headers` is a list of `{name, value}` |
| `Lettermint.HTTP` (internal) | `Lettermint.Adapter.Req`; pass Req options as `adapter: {Lettermint.Adapter.Req, options}` |

The SDK runs the adapter in a task and enforces the timeout itself. `{:error, reason}` becomes `Lettermint.ConnectionError` with that reason (`:timeout` becomes `Lettermint.TimeoutError`).

### Type names

The types are generated from the API specification of lettermint#2582 and use its names. They move from `Lettermint.Models` to `Lettermint.Types`. `Lettermint.Model.to_map/1` is now `Lettermint.Types.to_map/1`, and `Lettermint.Model.from_map/2` is `Lettermint.Types.decode/2`. Some shapes also changed:

- Enums are open, as before: unknown values decode as strings, and enum modules keep `values/0`.
- `SendMailResponse` (was `SendEmailResponse` and `SendBatchEmailResponseItem`) holds the fields of a pending and of a scheduled send; check `status`.
- `MessageTag` describes tags in responses; `MessageTagInput` describes tags you send (was `SendMailRequestTagsItem`).
- Every list is `Lettermint.Types.CursorPage` (see [Lists and pagination](#lists-and-pagination)). The per-list modules, such as `ListDomainsResponse`, are typespecs for `CursorPage.t(item)`.
- Query parameters have typespec modules, such as `Lettermint.Types.ListDomainsQuery`.
- Typespecs now tell required fields (`T`), optional fields (`T | :unset`) and nullable fields (`T | nil`) apart. 1.x typed every field as `T | nil | :unset`.

These types keep their name and only move from `Lettermint.Models` to `Lettermint.Types`:

`AttachmentDelivery`, `BuiltInTeamRole`, `DeliveryMode`, `DkimMode`, `DnsRecordPurpose`, `DnsRecordStatus`, `DnsVerificationScope`, `DomainData`, `DomainDataProjectsItem`, `DomainDnsRecordData`, `DomainListData`, `DomainStatus`, `GetReportForwardingResponse`, `InitialRoutes`, `MessageAttachmentData`, `MessageData`, `MessageEventData`, `MessageEventType`, `MessageListData`, `MessageRecipientData`, `MessageStatsData`, `MessageStatus`, `MessageType`, `Plan`, `ProcessInboundMessageResponse`, `ProjectAccessScope`, `ProjectCreatedData`, `ProjectData`, `ProjectListData`, `RbacConflictCode`, `RbacPermission`, `RecordType`, `ReportForwardingRequest`, `ReportForwardingResource`, `RescheduleMessageRequest`, `ResendReportForwardingCodeResponse`, `RouteData`, `RouteDataSettings`, `RouteListData`, `RouteStatisticData`, `RouteType`, `SandboxResult`, `SendMailRequest`, `SendMailRequestSettings`, `SpamSymbol`, `StatsDailyData`, `StatsData`, `StatsInboundData`, `StatsTotalsData`, `StatsTypeData`, `StoreDomainData`, `StoreProjectData`, `StoreRouteData`, `StoreSuppressionData`, `StoreWebhookData`, `SuppressedRecipientData`, `SuppressionAppliesTo`, `SuppressionReason`, `SuppressionScope`, `SuppressionSourceMessageData`, `SuppressionStoreResponse`, `SuppressionType`, `TeamAddonData`, `TeamData`, `TeamMemberData`, `TeamMemberDataRole`, `TeamMemberProjectAccessData`, `TeamMemberProjectAccessDataProjectsItem`, `TeamRoleData`, `TeamType`, `TeamUsageDetailData`, `TeamUsagePeriodData`, `TlsPolicy`, `UpdateDomainProjectsData`, `UpdateProjectData`, `UpdateReportForwardingResponse`, `UpdateRouteData`, `UpdateRouteInboundSettingsData`, `UpdateRouteSettingsData`, `UpdateTeamData`, `UpdateTeamMemberAssignmentData`, `UpdateTeamMemberAssignmentDataProjectAccess`, `UpdateWebhookData`, `VerifyReportForwardingRequest`, `VerifyReportForwardingResponse`, `WebhookBasicAuthData`, `WebhookData`, `WebhookDeliveryData`, `WebhookDeliveryListData`, `WebhookDeliveryModeFilter`, `WebhookDeliveryStatus`, `WebhookEvent`, `WebhookListData`, `WebhookScope`, `WebhookSecretData`

These types are renamed:

| 1.x (`Lettermint.Models.*`) | 2.0 (`Lettermint.Types.*`) |
| --- | --- |
| `CancelScheduledMessageResponse` | `ScheduledMessage` |
| `DomainDestroyResponse` | `MessageResponse` |
| `DomainIndexResponse` | `ListDomainsResponse` |
| `DomainUpdateProjectsResponse` | `DomainMutationResponse` |
| `DomainVerifyDnsRecordsResponse` | `DnsVerificationSuccessResponse` |
| `DomainVerifyDnsRecordsResponseRecommendedFailedRecordsItem` | `DnsVerificationFailedRecord` |
| `DomainVerifySpecificDnsRecordResponse` | `MessageResponse` |
| `MessageDataTagsItem` | `MessageTag` |
| `MessageEventDataTagsItem` | `MessageTag` |
| `MessageEventsResponse` | `ListMessageEventsResponse` |
| `MessageIndexResponse` | `ListMessagesResponse` |
| `MessageListDataTagsItem` | `MessageTag` |
| `ProcessInboundMessageResponseData` | `ProcessInboundMessageResult` |
| `ProjectDestroyResponse` | `MessageResponse` |
| `ProjectIndexResponse` | `ListProjectsResponse` |
| `ProjectRotateTokenResponse` | `RotateProjectTokenResponse` |
| `ProjectStoreResponse` | `ProjectCreatedData` |
| `ProjectUpdateResponse` | `ProjectMutationResponse` |
| `RescheduleMessageResponse` | `ScheduledMessage` |
| `RouteDestroyResponse` | `MessageResponse` |
| `RouteIndexResponse` | `ListRoutesResponse` |
| `RouteStoreResponse` | `RouteMutationResponse` |
| `RouteUpdateResponse` | `RouteMutationResponse` |
| `RouteVerifyInboundDomainResponse` | `InboundDomainVerificationResponse` |
| `RouteVerifyInboundDomainResponseData` | `InboundDomainVerification` |
| `SendBatchEmailResponseItem` | `SendMailResponse` |
| `SendBatchMailRequestItem` | `SendMailRequest` |
| `SendBatchMailRequestItemAttachmentsItem` | `MessageAttachmentInput` |
| `SendBatchMailRequestItemSettings` | `SendMailRequestSettings` |
| `SendBatchMailRequestItemTagsItem` | `MessageTagInput` |
| `SendEmailResponse` | `SendMailResponse` |
| `SendMailRequestAttachmentsItem` | `MessageAttachmentInput` |
| `SendMailRequestTagsItem` | `MessageTagInput` |
| `SuppressionDestroyResponse` | `DeleteSuppressionResponse` |
| `SuppressionIndexResponse` | `ListSuppressionsResponse` |
| `SuppressionStoreResponseData` | `SuppressionStoreResult` |
| `TeamMembersResponse` | `ListTeamMembersResponse` |
| `TeamRolesResponse` | `TeamRoleListResponse` |
| `TeamUpdateResponse` | `TeamMutationResponse` |
| `V1AnalyticsRequest` | `AnalyticsQuery` |
| `V1AnalyticsRequestCompare` | `AnalyticsComparison` |
| `V1AnalyticsRequestFiltersItem` | `AnalyticsFilter` |
| `V1AnalyticsRequestFiltersItemOperator` | `AnalyticsFilterOperator` |
| `V1AnalyticsRequestIncludeItem` | `AnalyticsSection` |
| `V1AnalyticsRequestInterval` | `AnalyticsInterval` |
| `V1AnalyticsRequestMetricsItem` | `AnalyticsMetric` |
| `V1AnalyticsRequestSort` | `AnalyticsSort` |
| `V1AnalyticsRequestSortDirection` | `AnalyticsSortDirection` |
| `V1AnalyticsRequestSortMetric` | `AnalyticsMetric` |
| `V1AnalyticsResponse` | `AnalyticsResponse` |
| `V1AnalyticsResponseData` | `AnalyticsResults` |
| `V1AnalyticsResponseDataBreakdownItem` | `AnalyticsBreakdownRow` |
| `V1AnalyticsResponseDataBreakdownItemChangeValue` | `AnalyticsMetricChange` |
| `V1AnalyticsResponseDataBreakdownItemMetrics` | `AnalyticsMetricValues` |
| `V1AnalyticsResponseDataBreakdownItemPrevious` | `AnalyticsComparisonValues` |
| `V1AnalyticsResponseDataBreakdownItemPreviousMetrics` | `AnalyticsMetricValues` |
| `V1AnalyticsResponseDataBreakdownItemPreviousRateBases` | `AnalyticsRateBases` |
| `V1AnalyticsResponseDataBreakdownItemPreviousRateBasesBounceRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataBreakdownItemPreviousRateBasesComplaintRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataBreakdownItemPreviousRateBasesDeferralRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataBreakdownItemPreviousRateBasesDeliveryRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataBreakdownItemPreviousRateBasesEffectiveDeliveryRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataBreakdownItemPreviousRateBasesHumanClickRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataBreakdownItemPreviousRateBasesHumanOpenRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataBreakdownItemRateBases` | `AnalyticsRateBases` |
| `V1AnalyticsResponseDataBreakdownItemRateBasesBounceRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataBreakdownItemRateBasesComplaintRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataBreakdownItemRateBasesDeferralRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataBreakdownItemRateBasesDeliveryRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataBreakdownItemRateBasesEffectiveDeliveryRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataBreakdownItemRateBasesHumanClickRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataBreakdownItemRateBasesHumanOpenRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataBreakdownItemTrendItem` | `AnalyticsTimeSeriesPoint` |
| `V1AnalyticsResponseDataBreakdownItemTrendItemChangeValue` | `AnalyticsMetricChange` |
| `V1AnalyticsResponseDataBreakdownItemTrendItemMetrics` | `AnalyticsMetricValues` |
| `V1AnalyticsResponseDataBreakdownItemTrendItemPrevious` | `AnalyticsComparisonValues` |
| `V1AnalyticsResponseDataBreakdownItemTrendItemPreviousMetrics` | `AnalyticsMetricValues` |
| `V1AnalyticsResponseDataBreakdownItemTrendItemPreviousRateBases` | `AnalyticsRateBases` |
| `V1AnalyticsResponseDataBreakdownItemTrendItemPreviousRateBasesBounceRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataBreakdownItemTrendItemPreviousRateBasesComplaintRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataBreakdownItemTrendItemPreviousRateBasesDeferralRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataBreakdownItemTrendItemPreviousRateBasesDeliveryRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataBreakdownItemTrendItemPreviousRateBasesEffectiveDeliveryRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataBreakdownItemTrendItemPreviousRateBasesHumanClickRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataBreakdownItemTrendItemPreviousRateBasesHumanOpenRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataBreakdownItemTrendItemRateBases` | `AnalyticsRateBases` |
| `V1AnalyticsResponseDataBreakdownItemTrendItemRateBasesBounceRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataBreakdownItemTrendItemRateBasesComplaintRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataBreakdownItemTrendItemRateBasesDeferralRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataBreakdownItemTrendItemRateBasesDeliveryRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataBreakdownItemTrendItemRateBasesEffectiveDeliveryRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataBreakdownItemTrendItemRateBasesHumanClickRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataBreakdownItemTrendItemRateBasesHumanOpenRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataSummary` | `AnalyticsSummary` |
| `V1AnalyticsResponseDataSummaryChangeValue` | `AnalyticsMetricChange` |
| `V1AnalyticsResponseDataSummaryMetrics` | `AnalyticsMetricValues` |
| `V1AnalyticsResponseDataSummaryPrevious` | `AnalyticsComparisonValues` |
| `V1AnalyticsResponseDataSummaryPreviousMetrics` | `AnalyticsMetricValues` |
| `V1AnalyticsResponseDataSummaryPreviousRateBases` | `AnalyticsRateBases` |
| `V1AnalyticsResponseDataSummaryPreviousRateBasesBounceRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataSummaryPreviousRateBasesComplaintRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataSummaryPreviousRateBasesDeferralRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataSummaryPreviousRateBasesDeliveryRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataSummaryPreviousRateBasesEffectiveDeliveryRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataSummaryPreviousRateBasesHumanClickRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataSummaryPreviousRateBasesHumanOpenRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataSummaryRateBases` | `AnalyticsRateBases` |
| `V1AnalyticsResponseDataSummaryRateBasesBounceRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataSummaryRateBasesComplaintRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataSummaryRateBasesDeferralRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataSummaryRateBasesDeliveryRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataSummaryRateBasesEffectiveDeliveryRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataSummaryRateBasesHumanClickRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataSummaryRateBasesHumanOpenRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataTimeSeriesItem` | `AnalyticsTimeSeriesPoint` |
| `V1AnalyticsResponseDataTimeSeriesItemChangeValue` | `AnalyticsMetricChange` |
| `V1AnalyticsResponseDataTimeSeriesItemMetrics` | `AnalyticsMetricValues` |
| `V1AnalyticsResponseDataTimeSeriesItemPrevious` | `AnalyticsComparisonValues` |
| `V1AnalyticsResponseDataTimeSeriesItemPreviousMetrics` | `AnalyticsMetricValues` |
| `V1AnalyticsResponseDataTimeSeriesItemPreviousRateBases` | `AnalyticsRateBases` |
| `V1AnalyticsResponseDataTimeSeriesItemPreviousRateBasesBounceRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataTimeSeriesItemPreviousRateBasesComplaintRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataTimeSeriesItemPreviousRateBasesDeferralRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataTimeSeriesItemPreviousRateBasesDeliveryRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataTimeSeriesItemPreviousRateBasesEffectiveDeliveryRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataTimeSeriesItemPreviousRateBasesHumanClickRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataTimeSeriesItemPreviousRateBasesHumanOpenRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataTimeSeriesItemRateBases` | `AnalyticsRateBases` |
| `V1AnalyticsResponseDataTimeSeriesItemRateBasesBounceRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataTimeSeriesItemRateBasesComplaintRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataTimeSeriesItemRateBasesDeferralRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataTimeSeriesItemRateBasesDeliveryRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataTimeSeriesItemRateBasesEffectiveDeliveryRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataTimeSeriesItemRateBasesHumanClickRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseDataTimeSeriesItemRateBasesHumanOpenRate` | `AnalyticsRateBase` |
| `V1AnalyticsResponseMeta` | `AnalyticsMeta` |
| `V1AnalyticsResponseMetaAlignment` | `AnalyticsMetaAlignment` |
| `V1AnalyticsResponseMetaCollectionCompleteness` | `AnalyticsMetaCollectionCompleteness` |
| `V1AnalyticsResponseMetaComparison` | `AnalyticsMetaComparison` |
| `V1AnalyticsResponseMetaInterval` | `AnalyticsInterval` |
| `V1AnalyticsResponseMetaTimeBasis` | `AnalyticsMetaTimeBasis` |
| `V1AnalyticsResponsePagination` | `AnalyticsPagination` |
| `V1BlockedFileTypesResponse` | `BlockedFileTypes` |
| `WebhookDeliveriesResponse` | `ListWebhookDeliveriesResponse` |
| `WebhookDestroyResponse` | `MessageResponse` |
| `WebhookIndexResponse` | `ListWebhooksResponse` |
| `WebhookRegenerateSecretResponse` | `WebhookSecretResponse` |
| `WebhookStoreResponse` | `WebhookSecretResponse` |
| `WebhookTestResponse` | `TestWebhookResponse` |
| `WebhookUpdateResponse` | `WebhookMutationResponse` |

### Removed types

lettermint#2582 removed these schemas from the API specification. 1.x exported all five:

| 1.x | 2.0 |
| --- | --- |
| `Lettermint.Models.AnalyticsResponseData` | Removed. Use `Lettermint.Types.AnalyticsResponse` (`data: AnalyticsResults`). |
| `Lettermint.Models.StatsRequestData` | Removed. Use `Lettermint.Types.GetStatsQuery`, the query of `Lettermint.Stats.retrieve/3`. |
| `Lettermint.Models.MessageIndexResponseMeta` | Removed. Message lists are flat `CursorPage` structs; read `page.next_cursor`. |
| `Lettermint.Models.MessageEventsResponseMeta` | Removed. Event lists are flat `CursorPage` structs. |
| `Lettermint.Models.SuppressionStoreResponseMessage1` | Removed. `SuppressionStoreResponse.message` is a string. |

### Removed modules and functions

| 1.x | 2.0 |
| --- | --- |
| `Lettermint.email(token, opts)` | `Lettermint.new([sending_token: token] ++ opts)` |
| `Lettermint.api(token, opts)` | `Lettermint.new([team_token: token] ++ opts)` |
| `%Lettermint.Client{surface: ..., token: ...}` | `%Lettermint.Client{}` holds both tokens, in closures; build it with `Lettermint.new/1,2` |
| `Lettermint.Email` | `Lettermint.Emails` (`send/3`, `send_batch/3`, `ping/2`, and the new `compose/2`) |
| `Lettermint.API` | `Lettermint.ping/2`, `Lettermint.analytics/3`, `Lettermint.blocked_file_types/2` |
| `Lettermint.EmailBuilder.new(client)` | `Lettermint.Emails.compose/2` |
| `Lettermint.EmailBuilder.attachments(builder, list)` | `Lettermint.EmailBuilder.attach/2` |
| `Lettermint.EmailBuilder.to_map(builder)` | `Lettermint.EmailBuilder.build/1` |
| `Lettermint.MessageTag` (`new!/2`) | `%{name: ..., value: ...}` maps or `%Lettermint.Types.MessageTagInput{}`, validated on send |
| `Lettermint.Model.to_map/1`, `from_map/2` | `Lettermint.Types.to_map/1`, `Lettermint.Types.decode/2` |
| `Lettermint.Models.*` | `Lettermint.Types.*` (see [Type names](#type-names)) |
| `%Lettermint.Error{kind: :api \| :transport \| :decode}` | One exception per kind (see [Errors](#errors)); `Lettermint.Error` has guards |
| `Lettermint.HTTP` | `Lettermint.Adapter.Req` |
| `Lettermint.Webhook.verify(body, signature, secret, opts)` | `Lettermint.Webhook.verify_signature(Lettermint.Webhook.new(secret), body, signature, opts)`, or `verify/4` with the headers |
| `Lettermint.Projects.retrieve_report_forwarding(client, id)` and the other `*_report_forwarding` functions | `Lettermint.Projects.ReportForwarding` |
| `Lettermint.Team.members(client, opts)`, `retrieve_member`, `update_member_assignment` | `Lettermint.Team.Members` |
| `Lettermint.Webhooks.deliveries(client, id, opts)`, `show_delivery` | `Lettermint.Webhooks.Deliveries` |
| `query:` and `headers:` request options | A query argument; custom headers are removed |
| `specs/operations.json` | `Lettermint.Operations` (generated) |
