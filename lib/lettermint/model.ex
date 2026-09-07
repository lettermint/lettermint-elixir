defmodule Lettermint.Model do
  @moduledoc "Convert API models to maps. Unknown response fields remain in `extra`."

  @doc "Convert a model or nested value to JSON data. Omit `:unset`; preserve explicit `nil`."
  def to_map(%{__struct__: module, extra: extra} = value) do
    Enum.reduce(module.__schema__(), extra, fn {wire, field, _}, acc ->
      case Map.fetch!(value, field) do
        :unset -> Map.delete(acc, wire)
        item -> Map.put(acc, wire, to_map(item))
      end
    end)
  end

  def to_map(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), to_map(item)} end)

  def to_map(value) when is_list(value), do: Enum.map(value, &to_map/1)
  def to_map(value), do: value

  @doc "Read a map into a generated model. No response keys are converted to new atoms."
  def from_map(module, value), do: decode(value, {:model, module})

  @doc false
  def decode(nil, _), do: nil
  def decode(value, :any), do: value
  def decode(value, :string) when is_binary(value), do: value
  def decode(value, :integer) when is_integer(value), do: value
  def decode(value, :number) when is_number(value), do: value
  def decode(value, :boolean) when is_boolean(value), do: value
  def decode(values, {:list, type}) when is_list(values), do: Enum.map(values, &decode(&1, type))
  def decode([], {:map, _}), do: %{}

  def decode(value, {:map, type}) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, decode(item, type)} end)

  def decode(value, {:model, module}) when is_map(value) do
    schema = module.__schema__()

    fields =
      for {wire, field, type} <- schema,
          Map.has_key?(value, wire),
          do: {field, decode(value[wire], type)}

    struct!(module, [{:extra, Map.drop(value, Enum.map(schema, &elem(&1, 0)))} | fields])
  end

  def decode(value, {:union, types}) do
    Enum.reduce_while(types, :no_match, fn type, _ ->
      try do
        {:halt, {:match, decode(value, type)}}
      rescue
        ArgumentError -> {:cont, :no_match}
      end
    end)
    |> case do
      {:match, result} -> result
      :no_match -> raise ArgumentError, "Response does not match an API type"
    end
  end

  def decode(_, _), do: raise(ArgumentError, "Response does not match an API type")
end
