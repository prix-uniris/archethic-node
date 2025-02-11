defmodule Archethic.SelfRepair.Sync do
  @moduledoc false

  alias Archethic.BeaconChain
  alias Archethic.BeaconChain.Subset.P2PSampling
  alias Archethic.BeaconChain.SummaryAggregate

  alias Archethic.Crypto

  alias Archethic.DB

  alias Archethic.PubSub

  alias Archethic.P2P
  alias Archethic.P2P.Node
  alias Archethic.P2P.Message

  alias __MODULE__.TransactionHandler

  alias Archethic.TaskSupervisor
  alias Archethic.TransactionChain

  alias Archethic.TransactionChain.TransactionSummary

  alias Archethic.Utils

  require Logger

  @bootstrap_info_last_sync_date_key "last_sync_time"

  @doc """
  Return the last synchronization date from the previous cycle of self repair

  If there are not previous stored date:
  - Try to the first enrollment date of the listed nodes
  - Otherwise take the current date
  """
  @spec last_sync_date() :: DateTime.t() | nil
  def last_sync_date do
    case DB.get_bootstrap_info(@bootstrap_info_last_sync_date_key) do
      nil ->
        Logger.info("Not previous synchronization date")
        Logger.info("We are using the default one")
        default_last_sync_date()

      timestamp ->
        date =
          timestamp
          |> String.to_integer()
          |> DateTime.from_unix!()

        Logger.info("Last synchronization date #{DateTime.to_string(date)}")
        date
    end
  end

  defp default_last_sync_date do
    case P2P.authorized_nodes() do
      [] ->
        nil

      nodes ->
        %Node{enrollment_date: enrollment_date} =
          nodes
          |> Enum.reject(&(&1.enrollment_date == nil))
          |> Enum.sort_by(& &1.enrollment_date)
          |> Enum.at(0)

        Logger.info(
          "We are taking the first node's enrollment date - #{DateTime.to_string(enrollment_date)}"
        )

        enrollment_date
    end
  end

  @doc """
  Persist the last sync date
  """
  @spec store_last_sync_date(DateTime.t()) :: :ok
  def store_last_sync_date(date = %DateTime{}) do
    timestamp =
      date
      |> DateTime.to_unix()
      |> Integer.to_string()

    DB.set_bootstrap_info(@bootstrap_info_last_sync_date_key, timestamp)

    Logger.info("Last sync date updated: #{DateTime.to_string(date)}")
  end

  @doc """
  Retrieve missing transactions from the missing beacon chain slots
  since the last sync date provided

  Beacon chain pools are retrieved from the given latest synchronization
  date including all the beacon subsets (i.e <<0>>, <<1>>, etc.)

  Once retrieved, the transactions are downloaded and stored if not exists locally
  """
  @spec load_missed_transactions(
          last_sync_date :: DateTime.t(),
          patch :: binary()
        ) :: :ok | {:error, :unreachable_nodes}
  def load_missed_transactions(last_sync_date = %DateTime{}, patch) when is_binary(patch) do
    Logger.info(
      "Fetch missed transactions from last sync date: #{DateTime.to_string(last_sync_date)}"
    )

    start = System.monotonic_time()

    last_sync_date
    |> BeaconChain.next_summary_dates()
    |> BeaconChain.fetch_summary_aggregates()
    |> tap(&ensure_summaries_download/1)
    |> Enum.each(&process_summary_aggregate(&1, patch))

    :telemetry.execute([:archethic, :self_repair], %{duration: System.monotonic_time() - start})
    Archethic.Bootstrap.NetworkConstraints.persist_genesis_address()
  end

  defp ensure_summaries_download(aggregates) do
    # Make sure the beacon summaries have been synchronized
    # from remote nodes to avoid self-repair to be acknowledged if those
    # cannot be reached
    node_public_key = Crypto.first_node_public_key()

    case P2P.authorized_and_available_nodes() do
      [%Node{first_public_key: ^node_public_key}] ->
        :ok

      authorized_nodes ->
        remaining_nodes =
          authorized_nodes
          |> Enum.reject(&(&1.first_public_key == node_public_key))
          |> Enum.count()

        if remaining_nodes > 0 and aggregates == [] do
          Logger.error("Cannot make the self-repair - Not reachable nodes")
          {:error, :unreachable_nodes}
        else
          :ok
        end
    end
  end

  @doc """
  Process beacon summary to synchronize the transactions involving.

  Each transactions from the beacon summary will be analyzed to determine
  if the node is a storage node for this transaction. If so, it will download the
  transaction from the closest storage nodes and replicate it locally.

  The P2P view will also be updated if some node information are inside the beacon chain to determine
  the readiness or the availability of a node.

  Also, the  number of transaction received and the fees burned during the beacon summary interval will be stored.
  """
  @spec process_summary_aggregate(SummaryAggregate.t(), binary()) :: :ok
  def process_summary_aggregate(
        %SummaryAggregate{
          summary_time: summary_time,
          transaction_summaries: transaction_summaries,
          p2p_availabilities: p2p_availabilities
        },
        node_patch
      ) do
    start_time = System.monotonic_time()

    transactions_to_sync =
      transaction_summaries
      |> Enum.reject(&TransactionChain.transaction_exists?(&1.address))
      |> Enum.filter(&TransactionHandler.download_transaction?/1)

    synchronize_transactions(transactions_to_sync, node_patch)

    :telemetry.execute(
      [:archethic, :self_repair, :process_aggregate],
      %{duration: System.monotonic_time() - start_time},
      %{nb_transactions: length(transactions_to_sync)}
    )

    p2p_availabilities
    |> Enum.reduce(%{}, fn {subset,
                            %{
                              node_availabilities: node_availabilities,
                              node_average_availabilities: node_average_availabilities,
                              end_of_node_synchronizations: end_of_node_synchronizations
                            }},
                           acc ->
      sync_node(end_of_node_synchronizations)

      reduce_p2p_availabilities(
        subset,
        summary_time,
        node_availabilities,
        node_average_availabilities,
        acc
      )
    end)
    |> Enum.each(&update_availabilities/1)

    update_statistics(summary_time, transaction_summaries)
  end

  defp synchronize_transactions([], _node_patch), do: :ok

  defp synchronize_transactions(transaction_summaries, node_patch) do
    Logger.info("Need to synchronize #{Enum.count(transaction_summaries)} transactions")
    Logger.debug("Transaction to sync #{inspect(transaction_summaries)}")

    Task.Supervisor.async_stream_nolink(
      TaskSupervisor,
      transaction_summaries,
      &TransactionHandler.download_transaction(&1, node_patch),
      on_timeout: :kill_task,
      timeout: Message.get_max_timeout() + 2000,
      max_concurrency: 100
    )
    |> Stream.filter(&match?({:ok, _}, &1))
    |> Stream.each(fn {:ok, tx} ->
      :ok = TransactionHandler.process_transaction(tx)
    end)
    |> Stream.run()
  end

  defp sync_node(end_of_node_synchronizations) do
    end_of_node_synchronizations
    |> Enum.each(fn public_key -> P2P.set_node_globally_synced(public_key) end)
  end

  defp reduce_p2p_availabilities(
         subset,
         time,
         node_availabilities,
         node_average_availabilities,
         acc
       ) do
    node_list = Enum.filter(P2P.list_nodes(), &(DateTime.diff(&1.enrollment_date, time) <= 0))

    subset_node_list = P2PSampling.list_nodes_to_sample(subset, node_list)

    node_availabilities
    |> Utils.bitstring_to_integer_list()
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {available_bit, index}, acc ->
      node = Enum.at(subset_node_list, index)
      avg_availability = Enum.at(node_average_availabilities, index)

      if available_bit == 1 and Node.synced?(node) do
        Map.put(acc, node, %{available?: true, average_availability: avg_availability})
      else
        Map.put(acc, node, %{available?: false, average_availability: avg_availability})
      end
    end)
  end

  defp update_availabilities(
         {%Node{first_public_key: node_key},
          %{available?: available?, average_availability: avg_availability}}
       ) do
    DB.register_p2p_summary(node_key, DateTime.utc_now(), available?, avg_availability)

    if available? do
      P2P.set_node_globally_available(node_key)
    else
      P2P.set_node_globally_unavailable(node_key)
      P2P.set_node_globally_unsynced(node_key)
    end

    P2P.set_node_average_availability(node_key, avg_availability)
  end

  defp update_statistics(date, []) do
    tps = DB.get_latest_tps()
    DB.register_stats(date, tps, 0, 0)
  end

  defp update_statistics(date, transaction_summaries) do
    nb_transactions = length(transaction_summaries)

    previous_summary_time =
      date
      |> Utils.truncate_datetime()
      |> BeaconChain.previous_summary_time()

    nb_seconds = abs(DateTime.diff(previous_summary_time, date))
    tps = nb_transactions / nb_seconds

    acc = 0

    burned_fees =
      transaction_summaries
      |> Enum.reduce(acc, fn %TransactionSummary{fee: fee}, acc -> acc + fee end)

    DB.register_stats(date, tps, nb_transactions, burned_fees)

    Logger.info(
      "TPS #{tps} on #{Utils.time_to_string(date)} with #{nb_transactions} transactions"
    )

    Logger.info("Burned fees #{burned_fees} on #{Utils.time_to_string(date)}")

    PubSub.notify_new_tps(tps, nb_transactions)
  end
end
