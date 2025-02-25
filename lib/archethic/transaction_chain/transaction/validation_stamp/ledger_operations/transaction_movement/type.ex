defmodule Archethic.TransactionChain.Transaction.ValidationStamp.LedgerOperations.TransactionMovement.Type do
  @moduledoc """
  Represents a type of transaction movement.
  """

  alias Archethic.Crypto
  alias Archethic.Utils

  @typedoc """
  Transaction movement can be:
  - UCO transfers
  - Token transfers. When it's a token transfer, the type indicates the address of token to transfer, followed by a token id to identify non-fungible asset
  """
  @type t() :: :UCO | {:token, Crypto.versioned_hash(), non_neg_integer()}

  def serialize(:UCO), do: <<0>>

  def serialize({:token, address, token_id}) do
    <<1::8, address::binary, token_id::8>>
  end

  def deserialize(<<0::8, rest::bitstring>>), do: {:UCO, rest}

  def deserialize(<<1::8, rest::bitstring>>) do
    {address, rest} = Utils.deserialize_address(rest)
    <<token_id::8, rest::bitstring>> = rest
    {{:token, address, token_id}, rest}
  end
end
