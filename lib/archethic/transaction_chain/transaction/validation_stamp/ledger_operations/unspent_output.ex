defmodule Archethic.TransactionChain.Transaction.ValidationStamp.LedgerOperations.UnspentOutput do
  @moduledoc """
  Represents an unspent output from a transaction.
  """
  defstruct [:amount, :from, :type, :timestamp, reward?: false]

  alias Archethic.Crypto

  alias Archethic.TransactionChain.Transaction.ValidationStamp.LedgerOperations.TransactionMovement.Type,
    as: TransactionMovementType

  alias Archethic.Utils

  @type t :: %__MODULE__{
          amount: non_neg_integer(),
          from: Crypto.versioned_hash(),
          type: TransactionMovementType.t()
        }

  @doc """
  Serialize unspent output into binary format

  ## Examples

   With UCO movements:

      iex> %UnspentOutput{
      ...>    from: <<0, 214, 107, 17, 107, 227, 11, 17, 43, 204, 48, 78, 129, 145, 126, 45, 68, 194,
      ...>      159, 19, 92, 240, 29, 37, 105, 183, 232, 56, 42, 163, 236, 251, 186>>,
      ...>    amount: 1_050_000_000,
      ...>    type: :UCO
      ...>  }
      ...>  |> UnspentOutput.serialize()
      <<
      # From
      0, 214, 107, 17, 107, 227, 11, 17, 43, 204, 48, 78, 129, 145, 126, 45, 68, 194,
      159, 19, 92, 240, 29, 37, 105, 183, 232, 56, 42, 163, 236, 251, 186,
      # Amount
      0, 0, 0, 0, 62, 149, 186, 128,
      # UCO Unspent Output
      0
      >>

  With Token movements:

      iex> %UnspentOutput{
      ...>    from: <<0, 214, 107, 17, 107, 227, 11, 17, 43, 204, 48, 78, 129, 145, 126, 45, 68, 194,
      ...>      159, 19, 92, 240, 29, 37, 105, 183, 232, 56, 42, 163, 236, 251, 186>>,
      ...>    amount: 1_050_000_000,
      ...>    type: {:token, <<0, 49, 101, 72, 154, 152, 3, 174, 47, 2, 35, 7, 92, 122, 206, 185, 71, 140, 74,
      ...>      197, 46, 99, 117, 89, 96, 100, 20, 0, 34, 181, 215, 143, 175>>, 0}
      ...>  }
      ...>  |> UnspentOutput.serialize()
      <<
      # From
      0, 214, 107, 17, 107, 227, 11, 17, 43, 204, 48, 78, 129, 145, 126, 45, 68, 194,
      159, 19, 92, 240, 29, 37, 105, 183, 232, 56, 42, 163, 236, 251, 186,
      # Amount
      0, 0, 0, 0, 62, 149, 186, 128,
      # Token Unspent Output
      1,
      # Token address
      0, 49, 101, 72, 154, 152, 3, 174, 47, 2, 35, 7, 92, 122, 206, 185, 71, 140, 74,
      197, 46, 99, 117, 89, 96, 100, 20, 0, 34, 181, 215, 143, 175,
      # Token ID
      0
      >>
  """
  @spec serialize(__MODULE__.t()) :: <<_::64, _::_*8>>
  def serialize(%__MODULE__{from: from, amount: amount, type: type}) do
    <<from::binary, amount::64, TransactionMovementType.serialize(type)::binary>>
  end

  @doc """
  Deserialize an encoded unspent output

  ## Examples

      iex> <<0, 0, 214, 107, 17, 107, 227, 11, 17, 43, 204, 48, 78, 129, 145, 126, 45, 68, 194,
      ...> 159, 19, 92, 240, 29, 37, 105, 183, 232, 56, 42, 163, 236, 251, 186,
      ...> 0, 0, 0, 0, 62, 149, 186, 128, 0>>
      ...> |> UnspentOutput.deserialize()
      {
        %UnspentOutput{
          from: <<0, 0, 214, 107, 17, 107, 227, 11, 17, 43, 204, 48, 78, 129, 145, 126, 45, 68, 194,
            159, 19, 92, 240, 29, 37, 105, 183, 232, 56, 42, 163, 236, 251, 186>>,
          amount: 1_050_000_000,
          type: :UCO
        },
        ""
      }

      iex> <<0, 0, 214, 107, 17, 107, 227, 11, 17, 43, 204, 48, 78, 129, 145, 126, 45, 68, 194,
      ...> 159, 19, 92, 240, 29, 37, 105, 183, 232, 56, 42, 163, 236, 251, 186,
      ...> 0, 0, 0, 0, 62, 149, 186, 128, 1, 0, 0, 49, 101, 72, 154, 152, 3, 174, 47, 2, 35, 7, 92, 122, 206, 185, 71, 140, 74,
      ...> 197, 46, 99, 117, 89, 96, 100, 20, 0, 34, 181, 215, 143, 175, 0>>
      ...> |> UnspentOutput.deserialize()
      {
        %UnspentOutput{
          from: <<0, 0, 214, 107, 17, 107, 227, 11, 17, 43, 204, 48, 78, 129, 145, 126, 45, 68, 194,
            159, 19, 92, 240, 29, 37, 105, 183, 232, 56, 42, 163, 236, 251, 186>>,
          amount: 1_050_000_000,
          type: {:token, <<0, 0, 49, 101, 72, 154, 152, 3, 174, 47, 2, 35, 7, 92, 122, 206, 185, 71, 140, 74,
            197, 46, 99, 117, 89, 96, 100, 20, 0, 34, 181, 215, 143, 175>>, 0},
        },
        ""
      }
  """
  @spec deserialize(bitstring()) :: {__MODULE__.t(), bitstring}
  def deserialize(data) when is_bitstring(data) do
    {address, <<amount::64, rest::bitstring>>} = Utils.deserialize_address(data)
    {type, rest} = TransactionMovementType.deserialize(rest)

    {
      %__MODULE__{
        from: address,
        amount: amount,
        type: type
      },
      rest
    }
  end

  @doc """
  Build %UnspentOutput struct from map

  ## Examples

      iex> %{
      ...>  from:  <<0, 0, 214, 107, 17, 107, 227, 11, 17, 43, 204, 48, 78, 129, 145, 126, 45, 68, 194,
      ...>  159, 19, 92, 240, 29, 37, 105, 183, 232, 56, 42, 163, 236, 251, 186>>,
      ...>  amount: 1_050_000_000,
      ...>  type: :UCO
      ...>  } |> UnspentOutput.cast()
      %UnspentOutput{
        from: <<0, 0, 214, 107, 17, 107, 227, 11, 17, 43, 204, 48, 78, 129, 145, 126, 45, 68, 194,159, 19, 92, 240, 29, 37, 105, 183, 232, 56, 42, 163, 236, 251, 186>>,
        amount: 1_050_000_000,
        type: :UCO,
        reward?: false,
        timestamp: nil
      }


      iex> %{
      ...>  from: <<0, 0, 214, 107, 17, 107, 227, 11, 17, 43, 204, 48, 78, 129, 145, 126, 45,
      ...>    68, 194, 159, 19, 92, 240, 29, 37, 105, 183, 232, 56, 42, 163, 236, 251, 186>>,
      ...>  amount: 1_050_000_000,
      ...>  type: {:token, <<0, 49, 101, 72, 154, 152, 3, 174, 47, 2, 35, 7, 92, 122, 206, 185, 71, 140, 74,
      ...>      197, 46, 99, 117, 89, 96, 100, 20, 0, 34, 181, 215, 143, 175>>, 0}
      ...> } |> UnspentOutput.cast()
      %UnspentOutput{
        from: <<0, 0, 214, 107, 17, 107, 227, 11, 17, 43, 204, 48, 78, 129, 145, 126, 45, 68, 194,159, 19, 92, 240, 29, 37, 105, 183, 232, 56, 42, 163, 236, 251, 186>>,
        amount: 1_050_000_000,
        type: {:token, <<0, 49, 101, 72, 154, 152, 3, 174, 47, 2, 35, 7, 92, 122, 206, 185, 71, 140, 74,197, 46, 99, 117, 89, 96, 100, 20, 0, 34, 181, 215, 143, 175>>, 0 },
        reward?: false,
        timestamp: nil
      }
  """
  @spec cast(map()) :: __MODULE__.t()
  def cast(unspent_output = %{}) do
    %__MODULE__{
      from: Map.get(unspent_output, :from),
      amount: Map.get(unspent_output, :amount),
      type: Map.get(unspent_output, :type)
    }
  end

  @doc """
  Convert %UnspentOutput{} Struct to a Map

  ## Examples

      iex> %UnspentOutput{
      ...> from: <<0, 0, 214, 107, 17, 107, 227, 11, 17, 43, 204, 48, 78, 129, 145, 126, 45, 68, 194,159, 19, 92, 240, 29, 37, 105, 183, 232, 56, 42, 163, 236, 251, 186>>,
      ...> amount: 1_050_000_000,
      ...> type: :UCO,
      ...> reward?: false,
      ...> timestamp: nil
      ...> }|> UnspentOutput.to_map()
      %{
        from:  <<0, 0, 214, 107, 17, 107, 227, 11, 17, 43, 204, 48, 78, 129, 145, 126, 45, 68, 194,159, 19, 92, 240, 29, 37, 105, 183, 232, 56, 42, 163, 236, 251, 186>>,
        amount: 1_050_000_000,
        type: "UCO",
        reward?: false,
        timestamp: nil
      }


      iex> %UnspentOutput{
      ...>  from: <<0, 0, 214, 107, 17, 107, 227, 11, 17, 43, 204, 48, 78, 129, 145, 126, 45,
      ...>   68, 194, 159, 19, 92, 240, 29, 37, 105, 183, 232, 56, 42, 163, 236, 251, 186>>,
      ...>  amount: 1_050_000_000,
      ...>  type: {:token, <<0, 49, 101, 72, 154, 152, 3, 174, 47, 2, 35, 7, 92, 122, 206, 185,
      ...>  71, 140, 74,  197, 46, 99, 117, 89, 96, 100, 20, 0, 34, 181, 215, 143, 175>>, 0 }
      ...> } |> UnspentOutput.to_map()
      %{
        from: <<0, 0, 214, 107, 17, 107, 227, 11, 17, 43, 204, 48, 78, 129, 145, 126, 45, 68,
        194,159, 19, 92, 240, 29, 37, 105, 183, 232, 56, 42, 163, 236, 251, 186>>,
        amount: 1_050_000_000,
        type: "token",
        token_address: <<0, 49, 101, 72, 154, 152, 3, 174, 47, 2, 35, 7, 92, 122, 206, 185, 71,
        140,74,197, 46, 99, 117, 89, 96, 100, 20, 0, 34, 181, 215, 143, 175>>,
        token_id: 0,
        reward?: false,
        timestamp: nil
      }


  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{
        from: from,
        amount: amount,
        type: :UCO,
        reward?: reward,
        timestamp: timestamp
      }) do
    %{
      from: from,
      amount: amount,
      type: "UCO",
      reward?: reward,
      timestamp: timestamp
    }
  end

  def to_map(%__MODULE__{
        from: from,
        amount: amount,
        type: {:token, token_address, token_id},
        reward?: reward,
        timestamp: timestamp
      }) do
    %{
      from: from,
      amount: amount,
      type: "token",
      token_address: token_address,
      token_id: token_id,
      reward?: reward,
      timestamp: timestamp
    }
  end
end
