defmodule UnirisCore.Mining.ProofOfWork do
  @moduledoc false

  alias UnirisCore.Transaction
  alias UnirisCore.Crypto
  alias UnirisCore.SharedSecrets
  alias UnirisCore.P2P
  alias UnirisCore.P2P.Node
  alias UnirisCore.Storage

  @spec run(Transaction.pending()) :: binary()
  def run(
        tx = %Transaction{
          type: :node,
          previous_public_key: previous_public_key,
          origin_signature: origin_signature
        }
      ) do
    signed_data = origin_signature_data_fields(tx)
    previous_address = Crypto.hash(previous_public_key)

    with {:ok, %Transaction{previous_public_key: previous_public_key}} <-
           Storage.get_transaction(previous_address),
         {:ok, %Node{first_public_key: first_public_key}} <- P2P.node_info(previous_public_key),
         true <- Crypto.verify(origin_signature, signed_data, first_public_key) do
      first_public_key
    else
      _ ->
        # When it's the first transaction
        if Crypto.verify(origin_signature, signed_data, previous_public_key) do
          previous_public_key
        else
          ""
        end
    end
  end

  def run(tx = %Transaction{type: :node_shared_secrets, origin_signature: origin_signature}) do
    origin_node_keys = Enum.map(P2P.list_nodes(), & &1.first_public_key)
    find_public_key(origin_signature, origin_signature_data_fields(tx), origin_node_keys)
  end

  def run(tx = %Transaction{origin_signature: origin_signature}) do
    find_public_key(
      origin_signature,
      origin_signature_data_fields(tx),
      SharedSecrets.origin_public_keys()
    )
  end

  ## Check recursively all the public key with the origin signature.
  ## Once the public key is found, the iteration is stopped
  @spec find_public_key(binary(), map(), list(binary())) :: binary()
  defp find_public_key(sig, data, [public_key | rest]) do
    if Crypto.verify(sig, data, public_key) do
      public_key
    else
      find_public_key(sig, data, rest)
    end
  end

  defp find_public_key(_sig, _data, []), do: ""

  defp find_public_key(sig, data, public_key) do
    if Crypto.verify(sig, data, public_key) do
      public_key
    else
      ""
    end
  end

  def verify?(tx = %Transaction{}, "") do
    if run(tx) == "" do
      true
    else
      false
    end
  end

  def verify?(tx = %Transaction{}, proof_of_work) when is_binary(proof_of_work) do
    Crypto.verify(
      tx.origin_signature,
      origin_signature_data_fields(tx),
      proof_of_work
    )
  end

  defp origin_signature_data_fields(tx = %Transaction{}) do
    Map.take(tx, [
      :address,
      :type,
      :timestamp,
      :data,
      :previous_public_key,
      :previous_signature
    ])
  end
end