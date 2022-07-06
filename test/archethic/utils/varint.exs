defmodule VarIntTest do
  use ExUnit.Case
  alias Archethic.Utils.VarInt

  doctest VarInt

  test "should encode 8 bit number" do
    assert VarInt.from_value(25) |> VarInt.serialize() == <<1::8, 25::8>>
  end

  test "should deserialize 8 bit encoded bitstring" do
    data = <<3, 2, 184, 169>>
    assert %VarInt{bytes: 3, value: 178_345} == data |> VarInt.deserialize()
  end

  test "should encode and decode randomly 100 integers" do
    numbers =
      1..100
      |> Enum.map(fn x -> Integer.pow(1..2048 |> Enum.random(), x) end)

    # Encode the numbers in structs
    struct_nums = numbers |> Enum.map(fn x -> x |> VarInt.from_value() end)

    # Serialize the numbers in bitstring
    serialized_numbers = struct_nums |> Enum.map(fn x -> x |> VarInt.serialize() end)

    # Deserialize the bitstrings to struct
    decoded_numbers = serialized_numbers |> Enum.map(fn x -> x |> VarInt.deserialize() end)

    assert length(struct_nums -- decoded_numbers) == 0
  end

  test "Should Raise an Error on Malformed Argument Supplied" do
    data = <<2, 34>>

    assert_raise ArgumentError, fn ->
      data |> VarInt.deserialize()
    end
  end
end