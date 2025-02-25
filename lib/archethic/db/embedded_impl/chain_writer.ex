defmodule Archethic.DB.EmbeddedImpl.ChainWriter do
  @moduledoc false

  use GenServer

  alias Archethic.DB.EmbeddedImpl.Encoding
  alias Archethic.DB.EmbeddedImpl.ChainIndex

  alias Archethic.TransactionChain.Transaction
  alias Archethic.TransactionChain.Transaction.ValidationStamp

  alias Archethic.BeaconChain.Summary

  alias Archethic.Utils

  alias Archethic.Crypto

  def start_link(arg \\ [], opts \\ []) do
    GenServer.start_link(__MODULE__, arg, opts)
  end

  @doc """
  Append a transaction to a file for the given genesis address
  """
  @spec append_transaction(binary(), Transaction.t()) :: :ok
  def append_transaction(genesis_address, tx = %Transaction{}) do
    partition = :erlang.phash2(genesis_address, 20)
    [{_, pid}] = :ets.lookup(:archethic_db_chain_writers, partition)
    GenServer.call(pid, {:append_tx, genesis_address, tx})
  end

  @doc """
  Write a beacon summary in a new file
  """
  @spec write_beacon_summary(Summary.t(), binary()) :: :ok
  def write_beacon_summary(
        summary = %Summary{subset: subset, summary_time: summary_time},
        db_path
      ) do
    start = System.monotonic_time()

    summary_address = Crypto.derive_beacon_chain_address(subset, summary_time, true)

    filename = beacon_path(db_path, summary_address)

    data = Summary.serialize(summary) |> Utils.wrap_binary()

    File.write!(
      filename,
      data,
      [:exclusive, :binary]
    )

    :telemetry.execute([:archethic, :db], %{duration: System.monotonic_time() - start}, %{
      query: "write_beacon_summary"
    })
  end

  def init(arg) do
    db_path = Keyword.get(arg, :path)
    partition = Keyword.get(arg, :partition)

    :ets.insert(:archethic_db_chain_writers, {partition, self()})

    setup_folders(db_path)

    {:ok, %{db_path: db_path, partition: partition}}
  end

  defp setup_folders(path) do
    path
    |> base_chain_path()
    |> File.mkdir_p!()

    path
    |> base_beacon_path()
    |> File.mkdir_p!()
  end

  def handle_call(
        {:append_tx, genesis_address, tx},
        _from,
        state = %{db_path: db_path}
      ) do
    write_transaction(genesis_address, tx, db_path)
    {:reply, :ok, state}
  end

  def terminate(_reason, _state = %{partition: partition}) do
    :ets.delete(:archethic_db_chain_writers, partition)
    :ignore
  end

  defp write_transaction(genesis_address, tx, db_path) do
    start = System.monotonic_time()

    filename = chain_path(db_path, genesis_address)

    data = Encoding.encode(tx)

    File.write!(
      filename,
      data,
      [:append, :binary]
    )

    index_transaction(tx, genesis_address, byte_size(data), db_path)

    :telemetry.execute([:archethic, :db], %{duration: System.monotonic_time() - start}, %{
      query: "write_transaction"
    })
  end

  defp index_transaction(
         %Transaction{
           address: tx_address,
           type: tx_type,
           previous_public_key: previous_public_key,
           validation_stamp: %ValidationStamp{timestamp: timestamp}
         },
         genesis_address,
         encoded_size,
         db_path
       ) do
    start = System.monotonic_time()

    ChainIndex.add_tx(tx_address, genesis_address, encoded_size, db_path)
    ChainIndex.add_tx_type(tx_type, tx_address, db_path)
    ChainIndex.set_last_chain_address(genesis_address, tx_address, timestamp, db_path)
    ChainIndex.set_public_key(genesis_address, previous_public_key, timestamp, db_path)

    :telemetry.execute([:archethic, :db], %{duration: System.monotonic_time() - start}, %{
      query: "index_transaction"
    })
  end

  @doc """
  Return the path of the chain storage location
  """
  @spec chain_path(String.t(), binary()) :: String.t()
  def chain_path(db_path, genesis_address)
      when is_binary(genesis_address) and is_binary(db_path) do
    Path.join([base_chain_path(db_path), Base.encode16(genesis_address)])
  end

  @doc """
  Return the chain base path
  """
  @spec base_chain_path(String.t()) :: String.t()
  def base_chain_path(db_path) do
    Path.join([db_path, "chains"])
  end

  @doc """
  Return the path of the sbeacon ummary storage location
  """
  @spec beacon_path(String.t(), binary()) :: String.t()
  def beacon_path(db_path, summary_address)
      when is_binary(summary_address) and is_binary(db_path) do
    Path.join([base_beacon_path(db_path), Base.encode16(summary_address)])
  end

  @doc """
  Return the beacon summary base path
  """
  @spec base_beacon_path(String.t()) :: String.t()
  def base_beacon_path(db_path) do
    Path.join([db_path, "beacon_summary"])
  end
end
