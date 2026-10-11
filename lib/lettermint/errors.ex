defmodule Lettermint.Error do
  @moduledoc """
  The errors of the Lettermint SDK.

  Every error is an exception struct. Functions that call the API return
  `{:error, error}`; `iterate/3` streams and `Lettermint.analytics_pages/3`
  raise the error instead. Configuration errors (`Lettermint.ConfigError`) are
  always raised, because they are programming errors: a missing or
  unrecognised token, an invalid option or an invalid ID.

  | Error | When | Fields |
  | --- | --- | --- |
  | `Lettermint.APIError` | Any other 4xx with a JSON or empty body | `status`, `code`, `message`, `details`, `body` |
  | `Lettermint.AuthenticationError` | 401 | as `APIError` |
  | `Lettermint.PermissionError` | 403 | as `APIError` |
  | `Lettermint.NotFoundError` | 404 | as `APIError` |
  | `Lettermint.ConflictError` | 409 | as `APIError` |
  | `Lettermint.ValidationError` | 422 | as `APIError`, plus `errors` |
  | `Lettermint.RateLimitError` | 429 | as `APIError`, plus `retry_after` (seconds) |
  | `Lettermint.ServerError` | 5xx | as `APIError`, plus `retry_after` (seconds, when the API sent `Retry-After`) |
  | `Lettermint.TimeoutError` | No complete response within the timeout | `timeout` |
  | `Lettermint.ConnectionError` | The request failed (DNS, TLS, refused, reset) | `reason` |
  | `Lettermint.UnexpectedResponseError` | An empty or non-JSON body where JSON was expected, or an error page such as a proxy's HTML 502 | `status`, `body_excerpt` |
  | `Lettermint.RedirectError` | A 3xx response; redirects are never followed | `status` |
  | `Lettermint.ConfigError` | Raised: a missing or unrecognised token, an invalid option or ID | |
  | `Lettermint.ClientValidationError` | The SDK rejected the request before sending it, such as invalid tags | `field` |
  | `Lettermint.WebhookVerificationError` | A webhook delivery is not genuine | `reason` |

  The guards in this module match the families:

      import Lettermint.Error, only: [is_api_error: 1]

      case Lettermint.Domains.retrieve(client, id) do
        {:ok, domain} -> domain
        {:error, %Lettermint.NotFoundError{}} -> nil
        {:error, error} when is_api_error(error) -> handle(error.status, error.code)
        {:error, error} -> raise error
      end

  No error contains request headers or API tokens.
  """

  @api_errors [
    Lettermint.APIError,
    Lettermint.AuthenticationError,
    Lettermint.PermissionError,
    Lettermint.NotFoundError,
    Lettermint.ConflictError,
    Lettermint.ValidationError,
    Lettermint.RateLimitError,
    Lettermint.ServerError
  ]

  @errors @api_errors ++
            [
              Lettermint.ConfigError,
              Lettermint.ClientValidationError,
              Lettermint.TimeoutError,
              Lettermint.ConnectionError,
              Lettermint.UnexpectedResponseError,
              Lettermint.RedirectError,
              Lettermint.WebhookVerificationError
            ]

  @typedoc "Any error of the SDK."
  @type t ::
          Lettermint.APIError.t()
          | Lettermint.AuthenticationError.t()
          | Lettermint.PermissionError.t()
          | Lettermint.NotFoundError.t()
          | Lettermint.ConflictError.t()
          | Lettermint.ValidationError.t()
          | Lettermint.RateLimitError.t()
          | Lettermint.ServerError.t()
          | Lettermint.TimeoutError.t()
          | Lettermint.ConnectionError.t()
          | Lettermint.UnexpectedResponseError.t()
          | Lettermint.RedirectError.t()
          | Lettermint.ClientValidationError.t()
          | Lettermint.ConfigError.t()
          | Lettermint.WebhookVerificationError.t()

  @doc "The modules of the API errors (`APIError` and its per-status variants)."
  @spec api_errors() :: [module()]
  def api_errors, do: @api_errors

  @doc "The modules of every SDK error."
  @spec errors() :: [module()]
  def errors, do: @errors

  @doc "True for any error of the SDK."
  defguard is_lettermint_error(term)
           when is_struct(term) and :erlang.map_get(:__struct__, term) in @errors

  @doc "True for `Lettermint.APIError` and its per-status variants."
  defguard is_api_error(term)
           when is_struct(term) and :erlang.map_get(:__struct__, term) in @api_errors
end

defmodule Lettermint.ConfigError do
  @moduledoc """
  The client was configured or called incorrectly: a missing or unrecognised
  token, a token that the called function cannot use, an invalid option or an
  invalid path parameter. Raised before any request is made.
  """
  defexception [:message]
  @type t :: %__MODULE__{message: String.t()}
end

defmodule Lettermint.ClientValidationError do
  @moduledoc """
  The SDK rejected a request before sending it, for example invalid message
  tags or a body that cannot be encoded as JSON. Unlike
  `Lettermint.ValidationError`, the API never saw this request.

  `field` names the offending field, for example `"tags"` or
  `"messages[2].tags"`.
  """
  defexception [:message, :field]
  @type t :: %__MODULE__{message: String.t(), field: String.t() | nil}
end

for {module, doc} <- [
      {Lettermint.APIError,
       "The API answered with an error status (4xx or 5xx) and a JSON or empty body. The per-status errors have the same fields."},
      {Lettermint.AuthenticationError, "HTTP 401: the token is missing, invalid or revoked."},
      {Lettermint.PermissionError,
       "HTTP 403: the token may not perform this action, or the plan lacks the feature."},
      {Lettermint.NotFoundError,
       "HTTP 404: the resource does not exist or is not visible to the token."},
      {Lettermint.ConflictError,
       "HTTP 409: the request conflicts with the current state, for example an Idempotency-Key reused with a different body."}
    ] do
  defmodule module do
    @moduledoc """
    #{doc}

      * `status`: the HTTP status code
      * `code`: the machine-readable code from `{"error": {"code": ...}}` or a string `error` field, or `nil`
      * `message`: the API's message, or `"HTTP <status>"`
      * `details`: `{"error": {"details": ...}}`, or `nil`
      * `body`: the decoded JSON body, or `nil` for an empty body
    """
    defexception [:status, :code, :message, :details, :body]

    @type t :: %__MODULE__{
            status: pos_integer(),
            code: String.t() | nil,
            message: String.t(),
            details: term(),
            body: term()
          }
  end
end

defmodule Lettermint.ValidationError do
  @moduledoc """
  HTTP 422: the API rejected the request data.

  Has the fields of `Lettermint.APIError`, plus `errors`: the field errors from
  Laravel's `{"message": ..., "errors": {...}}` body, when the API sent them.
  """
  defexception [:status, :code, :message, :details, :body, :errors]

  @type t :: %__MODULE__{
          status: 422,
          code: String.t() | nil,
          message: String.t(),
          details: term(),
          body: term(),
          errors: %{optional(String.t()) => [String.t()]} | nil
        }
end

defmodule Lettermint.RateLimitError do
  @moduledoc """
  HTTP 429: too many requests.

  Has the fields of `Lettermint.APIError`, plus `retry_after`: the seconds to
  wait, from the `Retry-After` header (seconds or an HTTP date), or `nil`.
  """
  defexception [:status, :code, :message, :details, :body, :retry_after]

  @type t :: %__MODULE__{
          status: 429,
          code: String.t() | nil,
          message: String.t(),
          details: term(),
          body: term(),
          retry_after: non_neg_integer() | nil
        }
end

defmodule Lettermint.ServerError do
  @moduledoc """
  HTTP 5xx with a JSON or empty body.

  Has the fields of `Lettermint.APIError`, plus `retry_after`: the seconds to
  wait, from the `Retry-After` header (seconds or an HTTP date), or `nil` when
  the API did not send one.
  """
  defexception [:status, :code, :message, :details, :body, :retry_after]

  @type t :: %__MODULE__{
          status: pos_integer(),
          code: String.t() | nil,
          message: String.t(),
          details: term(),
          body: term(),
          retry_after: non_neg_integer() | nil
        }
end

defmodule Lettermint.TimeoutError do
  @moduledoc """
  The request did not complete within the timeout. The timeout covers the
  whole request: connecting, sending, the response headers and the body. The
  API may still have processed the request.
  """
  defexception [:timeout]
  @type t :: %__MODULE__{timeout: pos_integer()}

  @impl true
  def message(%{timeout: timeout}),
    do: "The request to the Lettermint API timed out after #{timeout} ms."
end

defmodule Lettermint.ConnectionError do
  @moduledoc """
  The request could not be sent or the connection failed (DNS, TLS, refused,
  reset). `reason` is the HTTP client's error, for example a
  `Req.TransportError` with `reason: :econnrefused`.
  """
  defexception [:reason]
  @type t :: %__MODULE__{reason: term()}

  @impl true
  def message(%{reason: reason}) do
    detail =
      if is_exception(reason), do: Exception.message(reason), else: inspect(reason)

    "Could not reach the Lettermint API: #{detail}"
  end
end

defmodule Lettermint.UnexpectedResponseError do
  @moduledoc """
  The response could not be decoded: an empty or non-JSON body where JSON was
  expected, or an error status with a non-JSON body such as a proxy's HTML
  page. `body_excerpt` holds the first 200 characters of the body.
  """
  defexception [:message, :status, :body_excerpt]

  @type t :: %__MODULE__{message: String.t(), status: non_neg_integer(), body_excerpt: String.t()}
end

defmodule Lettermint.RedirectError do
  @moduledoc """
  The API answered with a redirect (3xx). The SDK never follows redirects, so
  that tokens are not sent to another location.
  """
  defexception [:status]
  @type t :: %__MODULE__{status: 300..399}

  @impl true
  def message(%{status: status}),
    do:
      "The Lettermint API answered with a redirect (HTTP #{status}). Redirects are not followed; check the :base_url option."
end

defmodule Lettermint.WebhookVerificationError do
  @moduledoc """
  A webhook delivery could not be verified. Reject the request and do not
  process its payload.

  `reason` is one of `:signature_header_missing`, `:signature_header_malformed`,
  `:delivery_header_missing`, `:delivery_timestamp_mismatch`,
  `:timestamp_out_of_tolerance`, `:signature_mismatch`, `:body_invalid` or
  `:payload_invalid`.
  """
  defexception [:reason, :message]

  @type reason ::
          :signature_header_missing
          | :signature_header_malformed
          | :delivery_header_missing
          | :delivery_timestamp_mismatch
          | :timestamp_out_of_tolerance
          | :signature_mismatch
          | :body_invalid
          | :payload_invalid

  @type t :: %__MODULE__{reason: reason(), message: String.t()}
end
