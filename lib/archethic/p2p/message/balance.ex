defmodule Archethic.P2P.Message.Balance do
  @moduledoc """
  Represents a message with the balance of a transaction
  """
  defstruct uco: 0, token: %{}

  @type t :: %__MODULE__{
          uco: non_neg_integer(),
          token: %{{binary(), non_neg_integer()} => non_neg_integer()}
        }
end
