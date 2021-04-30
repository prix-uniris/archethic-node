defmodule Uniris.SharedSecrets.NodeRenewal do
  @moduledoc """
  Represent the new node shared secrets renewal combining authorized nodes and secrets
  """
  defstruct [:authorized_nodes, :authorization_date, :secret]

  alias Uniris.Crypto

  alias Uniris.Election

  alias Uniris.P2P
  alias Uniris.P2P.Node

  alias Uniris.SelfRepair

  alias Uniris.TransactionChain.Transaction
  alias Uniris.TransactionChain.TransactionData
  alias Uniris.TransactionChain.TransactionData.Keys

  @type t :: %__MODULE__{
          authorized_nodes: list(Crypto.key()),
          secret: binary(),
          authorization_date: DateTime.t()
        }

  @doc """
  Determine if the local node is the initiator of the node renewal
  """
  @spec initiator?() :: boolean()
  def initiator? do

    if P2P.authorized_node?() do
      election_constraints = Election.get_storage_constraints()

      %Node{first_public_key: initiator_key} =
        next_address()
        |> Election.storage_nodes(P2P.authorized_nodes(), election_constraints)
        |> List.first()

      initiator_key == Crypto.node_public_key(0)
    else
      false
    end
  end

  defp next_address do
    key_index = Crypto.number_of_node_shared_secrets_keys()
    next_public_key = Crypto.node_shared_secrets_public_key(key_index + 1)
    Crypto.hash(next_public_key)
  end

  @doc """
  List the next authorized node public keys
  """
  @spec next_authorized_node_public_keys() :: list(Crypto.key())
  def next_authorized_node_public_keys do
    SelfRepair.get_latest_tps()
    |> Election.next_authorized_nodes(P2P.list_nodes(availability: :global))
    |> Enum.map(& &1.last_public_key)
  end

  @doc """
  Create a new transaction for node shared secrets renewal generating secret encrypted using the secret key
  for the authorized nodes public keys

  The secret keys is encrypted with the list of authorized nodes public keys

  The secret is segmented by 180 bytes ( multiple encryption of 32 bytes )
  |------------------------|------------------------------|------------------------------|
  | Daily Nonce (60 bytes) | Transaction Seed (60 bytes)  |   Network seed (60 bytes)    |
  |------------------------|------------------------------|------------------------------|
  """
  @spec new_node_shared_secrets_transaction(
          authorized_nodes_public_keys :: list(Crypto.key()),
          daily_nonce_seed :: binary(),
          secret_key :: binary()
        ) :: Transaction.t()
  def new_node_shared_secrets_transaction(
        authorized_node_public_keys,
        daily_nonce_seed,
        secret_key
      )
      when is_binary(daily_nonce_seed) and is_binary(secret_key) and
             is_list(authorized_node_public_keys) do
    {daily_nonce_public_key, _} = Crypto.generate_deterministic_keypair(daily_nonce_seed)

    secret =
      Crypto.aes_encrypt(daily_nonce_seed, secret_key) <>
        Crypto.encrypt_node_shared_secrets_transaction_seed(secret_key) <>
        Crypto.encrypt_network_pool_seed(secret_key)

    network_pool_address =
      Crypto.number_of_network_pool_keys()
      |> Crypto.network_pool_public_key()
      |> Crypto.hash()

    Transaction.new(
      :node_shared_secrets,
      %TransactionData{
        content: """
        daily nonce public_key: #{Base.encode16(daily_nonce_public_key)}
        network pool address: #{Base.encode16(network_pool_address)}
        """,
        keys: Keys.new(authorized_node_public_keys, secret_key, secret)
      }
    )
  end
end
