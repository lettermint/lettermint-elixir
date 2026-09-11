defmodule Lettermint.MessageTag do
  @moduledoc "A reusable exact-match message tag."
  @enforce_keys [:name, :value]
  defstruct [:name, :value, extra: %{}]

  @type t :: %__MODULE__{name: String.t(), value: String.t(), extra: map()}

  @spec new!(String.t(), String.t()) :: t()
  def new!(name, value) when is_binary(name) and is_binary(value) do
    unless Regex.match?(~r/\A[A-Za-z0-9_-]{1,32}\z/, name),
      do: raise(ArgumentError, "Message tag names must match ^[A-Za-z0-9_-]{1,32}$")

    if String.starts_with?(String.downcase(name), "__lettermint"),
      do: raise(ArgumentError, "Message tag names must not start with __lettermint")

    unless Regex.match?(~r/\A[A-Za-z0-9_-]{1,64}\z/, value),
      do: raise(ArgumentError, "Message tag values must match ^[A-Za-z0-9_-]{1,64}$")

    %__MODULE__{name: name, value: value}
  end

  def new!(_, _), do: raise(ArgumentError, "Message tag names and values must be strings")

  @doc false
  def __schema__, do: [{"name", :name, :string}, {"value", :value, :string}]
end
