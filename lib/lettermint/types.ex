defmodule Lettermint.Types do
  @moduledoc """
  The API types, and helpers to convert them.

  `Lettermint.Types.*` is generated from the Lettermint API specification
  (`lib/lettermint/generated/types.ex`). Responses decode into these structs:

    * Every field defaults to `:unset`. A field the API did not send stays
      `:unset`; JSON `null` is `nil`.
    * `extra` holds response fields that this version of the SDK does not
      know, with string keys.
    * Enums are open: a value the API adds later decodes as its string.
      `values/0` on an enum module lists the values known to the SDK.
    * Decoding never creates atoms from response data, and never fails on an
      unexpected value: a value of another type than documented is kept as
      decoded from JSON.
    * Every list response is a `Lettermint.Types.CursorPage`, whose `data`
      holds the items.

  Requests take these structs or plain maps with atom or string keys, in the
  API's field names (`reply_to`, `scheduled_at`, ...).
  """

  @doc """
  Converts a struct (or a map or list holding structs) to JSON-ready data with
  string keys, in the API's field names. `:unset` fields are left out, `nil`
  stays `nil` (JSON `null`) and `extra` fields are kept.

      iex> Lettermint.Types.to_map(%Lettermint.Types.StoreDomainData{domain: "acme.com"})
      %{"domain" => "acme.com"}
  """
  @spec to_map(term()) :: term()
  def to_map(%module{extra: extra} = struct) when is_map(extra) do
    if function_exported?(module, :__fields__, 0) do
      Enum.reduce(module.__fields__(), to_map(extra), fn {field, wire, _spec}, acc ->
        case Map.fetch!(struct, field) do
          :unset -> Map.delete(acc, wire)
          value -> Map.put(acc, wire, to_map(value))
        end
      end)
    else
      struct
    end
  end

  def to_map(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def to_map(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def to_map(%Date{} = value), do: Date.to_iso8601(value)
  def to_map(%_{} = struct), do: struct

  def to_map(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key(key), to_map(value)} end)

  def to_map(list) when is_list(list), do: Enum.map(list, &to_map/1)
  def to_map(value) when is_boolean(value) or is_nil(value), do: value
  def to_map(value) when is_atom(value), do: Atom.to_string(value)
  def to_map(value), do: value

  defp key(key) when is_atom(key), do: Atom.to_string(key)
  defp key(key), do: key

  @doc """
  Decodes JSON data (string keys, as from `Jason.decode/1`) into a type.

      iex> Lettermint.Types.decode(%{"domain" => "acme.com", "new" => 1}, Lettermint.Types.DomainData)
      %Lettermint.Types.DomainData{domain: "acme.com", extra: %{"new" => 1}}
  """
  @spec decode(term(), module()) :: term()
  def decode(value, module) when is_atom(module), do: decode_spec(value, module.__type__())

  @doc false
  def decode_spec(nil, _spec), do: nil
  def decode_spec(value, :any), do: value
  def decode_spec(value, scalar) when scalar in [:string, :integer, :number, :boolean], do: value
  def decode_spec(value, {:enum, _module}), do: value
  def decode_spec(value, {:ref, module}), do: decode_spec(value, module.__type__())

  def decode_spec(value, {:list, spec}) when is_list(value),
    do: Enum.map(value, &decode_spec(&1, spec))

  # PHP encodes an empty map as [].
  def decode_spec([], {:map, _spec}), do: %{}

  def decode_spec(value, {:map, spec}) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, decode_spec(item, spec)} end)

  def decode_spec([], {:model, module}), do: decode_spec(%{}, {:model, module})

  def decode_spec(value, {:model, module}) when is_map(value),
    do: decode_struct(value, module, %{})

  def decode_spec(value, {:page, item}) when is_map(value) do
    data = Map.get(value, "data")
    decoded = if is_list(data), do: Enum.map(data, &decode_spec(&1, item)), else: data
    decode_struct(value, Lettermint.Types.CursorPage, %{data: decoded})
  end

  def decode_spec(value, {:union, specs}) do
    case Enum.find(specs, &matches?(value, &1)) do
      nil -> value
      spec -> decode_spec(value, spec)
    end
  end

  def decode_spec(value, _spec), do: value

  defp decode_struct(value, module, overrides) do
    fields = module.__fields__()

    decoded =
      for {field, wire, spec} <- fields, Map.has_key?(value, wire), into: %{} do
        {field,
         Map.get_lazy(overrides, field, fn -> decode_spec(Map.fetch!(value, wire), spec) end)}
      end

    extra = Map.drop(value, Enum.map(fields, &elem(&1, 1)))
    struct(module, Map.put(decoded, :extra, extra))
  end

  defp matches?(value, {:ref, module}), do: matches?(value, module.__type__())
  defp matches?(value, :string), do: is_binary(value)
  defp matches?(value, {:enum, _}), do: is_binary(value)
  defp matches?(value, :integer), do: is_integer(value)
  defp matches?(value, :number), do: is_number(value)
  defp matches?(value, :boolean), do: is_boolean(value)
  defp matches?(value, {:list, _}), do: is_list(value)
  defp matches?(value, {:map, _}), do: is_map(value)
  defp matches?(value, {:model, _}), do: is_map(value)
  defp matches?(value, {:page, _}), do: is_map(value)
  defp matches?(value, {:union, specs}), do: Enum.any?(specs, &matches?(value, &1))
  defp matches?(_value, :any), do: true
end
