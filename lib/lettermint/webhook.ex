defmodule Lettermint.Webhook do
  @moduledoc "Verify a webhook signature against the original request body."
  @doc "Return `:ok` or `{:error, :invalid_signature}`. Default time tolerance: 300 seconds."
  def verify(body, signature, secret, opts \\ []) do
    now = Keyword.get(opts, :now, System.system_time(:second))
    tolerance = Keyword.get(opts, :tolerance, 300)

    parts =
      signature |> String.split(",") |> Enum.map(&String.split(String.trim(&1), "=", parts: 2))

    timestamps = for ["t", value] <- parts, do: value
    hashes = for ["v1", value] <- parts, do: value

    with [timestamp] <- timestamps,
         {time, ""} <- Integer.parse(timestamp),
         true <- is_integer(tolerance) and tolerance >= 0 and abs(now - time) <= tolerance do
      expected = :crypto.mac(:hmac, :sha256, secret, timestamp <> "." <> body)

      if Enum.any?(hashes, fn hash ->
           case Base.decode16(hash, case: :mixed) do
             {:ok, actual} when byte_size(actual) == byte_size(expected) ->
               :crypto.hash_equals(expected, actual)

             _ ->
               false
           end
         end), do: :ok, else: {:error, :invalid_signature}
    else
      _ -> {:error, :invalid_signature}
    end
  rescue
    _ -> {:error, :invalid_signature}
  end
end
