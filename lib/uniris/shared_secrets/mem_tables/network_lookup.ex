defmodule Uniris.SharedSecrets.MemTables.NetworkLookup do
  @moduledoc false

  alias Uniris.Bootstrap.NetworkInit
  alias Uniris.Crypto

  use GenServer

  @table_name :uniris_shared_secrets_network

  @genesis_daily_nonce_public_key Application.compile_env!(:uniris, [
                                    NetworkInit,
                                    :genesis_daily_nonce_seed
                                  ])
                                  |> Crypto.generate_deterministic_keypair()
                                  |> elem(0)

  def start_link(args \\ []) do
    GenServer.start_link(__MODULE__, args)
  end

  def init(_) do
    :ets.new(@table_name, [:ordered_set, :named_table, :public, read_concurrency: true])
    :ets.insert(@table_name, {{:daily_nonce, 0}, @genesis_daily_nonce_public_key})

    {:ok, []}
  end

  @doc """
  Define the last network pool address

  ## Examples

      iex> NetworkLookup.start_link()
      iex> NetworkLookup.set_network_pool_address(
      ...>   <<120, 232, 56, 47, 135, 12, 110, 76, 250, 5, 240, 210, 92, 165, 151, 239, 181,
      ...>   101, 24, 29, 24, 245, 231, 225, 47, 78, 103, 57, 254, 206, 159, 217>>
      ...> )
      iex> :ets.tab2list(:uniris_shared_secrets_network)
      [
        {:network_pool_address, <<120, 232, 56, 47, 135, 12, 110, 76, 250, 5, 240, 210, 92, 165,
          151, 239, 181,  101, 24, 29, 24, 245, 231, 225, 47, 78, 103, 57, 254, 206, 159, 217>>},
        {{:daily_nonce, 0}, <<0, 207, 10, 216, 159, 45, 111, 246, 18, 53, 128, 31, 127, 69, 104, 136, 74, 244, 225, 71, 122, 199, 230, 122, 233, 123, 61, 92, 150, 157, 139, 218, 8>>}
      ]
  """
  @spec set_network_pool_address(binary()) :: :ok
  def set_network_pool_address(address) when is_binary(address) do
    true = :ets.insert(@table_name, {:network_pool_address, address})
    :ok
  end

  @doc """
  Retrieve the last network pool address

  ## Examples

      iex> NetworkLookup.start_link()
      iex> NetworkLookup.set_network_pool_address(
      ...>   <<120, 232, 56, 47, 135, 12, 110, 76, 250, 5, 240, 210, 92, 165, 151, 239, 181,
      ...>   101, 24, 29, 24, 245, 231, 225, 47, 78, 103, 57, 254, 206, 159, 217>>
      ...> )
      iex> NetworkLookup.get_network_pool_address()
      <<120, 232, 56, 47, 135, 12, 110, 76, 250, 5, 240, 210, 92, 165, 151, 239, 181,
        101, 24, 29, 24, 245, 231, 225, 47, 78, 103, 57, 254, 206, 159, 217>>
  """
  @spec get_network_pool_address :: binary()
  def get_network_pool_address do
    case :ets.lookup(@table_name, :network_pool_address) do
      [{_, key}] ->
        key

      _ ->
        ""
    end
  end

  @doc """
  Define a daily nonce public key at a given time

  ## Examples

      iex> NetworkLookup.start_link()
      iex> NetworkLookup.set_daily_nonce_public_key(<<0, 57, 24, 251, 164, 133, 168, 109, 154, 9, 77, 197, 254, 138, 187, 250, 200, 37,
      ...>  115, 182, 174, 90, 206, 161, 228, 197, 77, 184, 101, 183, 164, 187, 96>>, ~U[2021-04-06 08:36:41Z])
      iex> NetworkLookup.set_daily_nonce_public_key(<<0, 52, 242, 87, 194, 41, 203, 59, 163, 197, 116, 83, 28, 134, 140, 48, 74, 66,
      ...>  21, 248, 239, 162, 234, 35, 220, 113, 133, 73, 255, 58, 134, 225, 30>>, ~U[2021-04-07 08:36:41Z])
      iex> :ets.tab2list(:uniris_shared_secrets_network)
      [
        {{:daily_nonce, 0}, <<0, 207, 10, 216, 159, 45, 111, 246, 18, 53, 128, 31, 127, 69, 104, 136, 74, 244, 225, 71, 122, 199, 230, 122, 233, 123, 61, 92, 150, 157, 139, 218, 8>>},
        {{:daily_nonce, 1617698201}, <<0, 57, 24, 251, 164, 133, 168, 109, 154, 9, 77, 197, 254, 138, 187, 250, 200, 37,
          115, 182, 174, 90, 206, 161, 228, 197, 77, 184, 101, 183, 164, 187, 96>>},
        {{:daily_nonce, 1617784601}, <<0, 52, 242, 87, 194, 41, 203, 59, 163, 197, 116, 83, 28, 134, 140, 48, 74, 66,
          21, 248, 239, 162, 234, 35, 220, 113, 133, 73, 255, 58, 134, 225, 30>>}
      ]
  """
  @spec set_daily_nonce_public_key(Crypto.key(), DateTime.t()) :: :ok
  def set_daily_nonce_public_key(public_key, date = %DateTime{}) when is_binary(public_key) do
    true = :ets.insert(@table_name, {{:daily_nonce, DateTime.to_unix(date)}, public_key})
    :ok
  end

  @doc """
  Retrieve the last daily nonce public key before current datetime

  ## Examples

      iex> NetworkLookup.start_link()
      iex> NetworkLookup.set_daily_nonce_public_key(<<0, 57, 24, 251, 164, 133, 168, 109, 154, 9, 77, 197, 254, 138, 187, 250, 200, 37,
      ...>  115, 182, 174, 90, 206, 161, 228, 197, 77, 184, 101, 183, 164, 187, 96>>, DateTime.utc_now() |> DateTime.add(-10))
      iex> NetworkLookup.set_daily_nonce_public_key(<<0, 52, 242, 87, 194, 41, 203, 59, 163, 197, 116, 83, 28, 134, 140, 48, 74, 66,
      ...>  21, 248, 239, 162, 234, 35, 220, 113, 133, 73, 255, 58, 134, 225, 30>>, DateTime.utc_now())
      iex> NetworkLookup.get_daily_nonce_public_key()
      <<0, 57, 24, 251, 164, 133, 168, 109, 154, 9, 77, 197, 254, 138, 187, 250, 200, 37, 115, 182, 174, 90, 206, 161, 228, 197, 77, 184, 101, 183, 164, 187, 96>>
  """
  @spec get_daily_nonce_public_key :: Crypto.key()
  def get_daily_nonce_public_key do
    do_get_daily_nonce_public_key(DateTime.utc_now())
  end

  @doc """
  Retrieve the last daily nonce public key at a given date

  ## Examples

      iex> NetworkLookup.start_link()
      iex> NetworkLookup.set_daily_nonce_public_key(<<0, 57, 24, 251, 164, 133, 168, 109, 154, 9, 77, 197, 254, 138, 187, 250, 200, 37,
      ...>  115, 182, 174, 90, 206, 161, 228, 197, 77, 184, 101, 183, 164, 187, 96>>, ~U[2021-04-06 08:36:41Z])
      iex> NetworkLookup.set_daily_nonce_public_key(<<0, 52, 242, 87, 194, 41, 203, 59, 163, 197, 116, 83, 28, 134, 140, 48, 74, 66,
      ...>  21, 248, 239, 162, 234, 35, 220, 113, 133, 73, 255, 58, 134, 225, 30>>, ~U[2021-04-07 08:36:41Z])
      iex> NetworkLookup.get_daily_nonce_public_key_at(~U[2021-04-07 10:00:00Z])
      <<0, 52, 242, 87, 194, 41, 203, 59, 163, 197, 116, 83, 28, 134, 140, 48, 74, 66, 21, 248, 239, 162, 234, 35, 220, 113, 133, 73, 255, 58, 134, 225, 30>>
      iex> NetworkLookup.get_daily_nonce_public_key_at(~U[2021-04-07 08:36:41Z])
      <<0, 57, 24, 251, 164, 133, 168, 109, 154, 9, 77, 197, 254, 138, 187, 250, 200, 37, 115, 182, 174, 90, 206, 161, 228, 197, 77, 184, 101, 183, 164, 187, 96>>
      iex> NetworkLookup.get_daily_nonce_public_key_at(~U[2021-04-07 00:00:00Z])
      <<0, 57, 24, 251, 164, 133, 168, 109, 154, 9, 77, 197, 254, 138, 187, 250, 200, 37, 115, 182, 174, 90, 206, 161, 228, 197, 77, 184, 101, 183, 164, 187, 96>>

  """
  @spec get_daily_nonce_public_key_at(DateTime.t()) :: Crypto.key()
  def get_daily_nonce_public_key_at(date = %DateTime{}) do
    do_get_daily_nonce_public_key(date)
  end

  defp do_get_daily_nonce_public_key(date) do
    unix_time = DateTime.to_unix(date)

    case :ets.prev(@table_name, {:daily_nonce, unix_time}) do
      :"$end_of_table" ->
        @genesis_daily_nonce_public_key

      key ->
        [{_, key}] = :ets.lookup(@table_name, key)
        key
    end
  end
end