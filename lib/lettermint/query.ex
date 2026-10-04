defmodule Lettermint.Query do
  @moduledoc """
  Serializes query maps to the API's bracket syntax, exactly as the Node SDK.

      iex> Lettermint.Query.encode(%{page: %{size: 10}, filter: %{status: "verified"}, sort: ["-created_at"]})
      "filter%5Bstatus%5D=verified&page%5Bsize%5D=10&sort=-created_at"

    * nested maps (or keyword lists) become bracketed names: `page[size]`;
    * lists of values are joined with commas: `sort=-created_at,domain`;
    * lists of maps are indexed: `filter[tags][0][name]=a`;
    * booleans are `1` or `0`; `DateTime`, `NaiveDateTime` and `Date` are ISO 8601;
    * `nil` values and empty lists are left out.

  Keys of a map are sent in sorted order; keyword lists keep their order.
  Names and values are form-encoded like `URLSearchParams`.
  """

  @doc "Encodes a query map. Raises `Lettermint.ConfigError` for values that cannot be sent."
  @spec encode(map() | keyword() | nil) :: String.t()
  def encode(nil), do: ""

  def encode(query) when is_map(query) or is_list(query) do
    query
    |> entries()
    |> Enum.flat_map(fn {key, value} -> append(name(key), value) end)
    |> Enum.map_join("&", fn {key, value} -> form(key) <> "=" <> form(value) end)
  end

  @doc false
  # Returns `query` with the parameter at wire name `name` (`cursor` or `page[cursor]`) set to `value`.
  def put(query, name, value) do
    query = Map.new(entries(query || %{}), fn {key, item} -> {name(key), item} end)

    case Regex.run(~r/\A([^\[\]]+)\[([^\[\]]+)\]\z/, name) do
      [_, group, key] ->
        current =
          case Map.get(query, group) do
            nested when is_map(nested) or is_list(nested) ->
              Map.new(entries(nested), fn {k, v} -> {name(k), v} end)

            _ ->
              %{}
          end

        query |> Map.delete(name) |> Map.put(group, Map.put(current, key, value))

      nil ->
        Map.put(query, name, value)
    end
  end

  defp entries(%_{} = struct), do: struct |> Lettermint.Types.to_map() |> entries()
  defp entries(map) when is_map(map), do: Enum.sort_by(map, fn {key, _} -> name(key) end)

  defp entries(list) when is_list(list) do
    if object_list?(list) do
      list
    else
      raise Lettermint.ConfigError, "A query must be a map; got a list."
    end
  end

  defp name(key) when is_binary(key), do: key
  defp name(key) when is_atom(key), do: Atom.to_string(key)
  defp name(key) when is_integer(key), do: Integer.to_string(key)

  defp name(key),
    do:
      raise(
        Lettermint.ConfigError,
        "Query parameter names must be atoms or strings, got #{inspect(key)}."
      )

  defp append(_key, nil), do: []

  defp append(key, list) when is_list(list) and list != [] do
    cond do
      object_list?(list) ->
        Enum.flat_map(list, fn {name, item} -> append("#{key}[#{name(name)}]", item) end)

      Enum.all?(list, &scalar?/1) ->
        case for(item <- list, not is_nil(item), do: scalar(item)) do
          [] -> []
          items -> [{key, Enum.join(items, ",")}]
        end

      true ->
        list
        |> Enum.with_index()
        |> Enum.flat_map(fn {item, index} -> append("#{key}[#{index}]", item) end)
    end
  end

  defp append(_key, []), do: []

  defp append(key, value) do
    cond do
      scalar?(value) ->
        [{key, scalar(value)}]

      is_map(value) ->
        value
        |> entries()
        |> Enum.flat_map(fn {name, item} -> append("#{key}[#{name(name)}]", item) end)

      true ->
        raise Lettermint.ConfigError,
              "The query parameter #{key} has a value that cannot be sent: #{inspect(value)}."
    end
  end

  defp object_list?([_ | _] = list),
    do: Enum.all?(list, &match?({key, _} when is_atom(key) or is_binary(key), &1))

  defp object_list?(_), do: false

  defp scalar?(value),
    do:
      is_nil(value) or is_binary(value) or is_number(value) or is_atom(value) or
        is_struct(value, DateTime) or is_struct(value, NaiveDateTime) or is_struct(value, Date)

  defp scalar(true), do: "1"
  defp scalar(false), do: "0"
  defp scalar(value) when is_binary(value), do: value
  defp scalar(value) when is_integer(value), do: Integer.to_string(value)
  defp scalar(value) when is_float(value), do: to_string(value)
  defp scalar(value) when is_atom(value), do: Atom.to_string(value)
  defp scalar(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp scalar(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp scalar(%Date{} = value), do: Date.to_iso8601(value)

  # application/x-www-form-urlencoded as URLSearchParams serializes it: keep
  # A-Z a-z 0-9 * - . _, send spaces as +, percent-encode every other byte.
  defp form(value) do
    for <<byte <- value>>, into: "" do
      cond do
        byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte in [?*, ?-, ?., ?_] -> <<byte>>
        byte == ?\s -> "+"
        true -> "%" <> Base.encode16(<<byte>>)
      end
    end
  end
end
