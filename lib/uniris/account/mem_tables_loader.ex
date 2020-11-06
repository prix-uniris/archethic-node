defmodule Uniris.Account.MemTablesLoader do
  @moduledoc false

  use GenServer

  alias Uniris.Account.MemTables.UCOLedger

  alias Uniris.Bootstrap

  alias Uniris.Crypto

  alias Uniris.TransactionChain
  alias Uniris.TransactionChain.Transaction
  alias Uniris.TransactionChain.Transaction.ValidationStamp
  alias Uniris.TransactionChain.Transaction.ValidationStamp.LedgerOperations
  alias Uniris.TransactionChain.Transaction.ValidationStamp.LedgerOperations.UnspentOutput

  require Logger

  @query_fields [
    :address,
    :previous_public_key,
    validation_stamp: [
      ledger_operations: [:node_movements, :unspent_outputs, :transaction_movements]
    ]
  ]

  def start_link(args \\ []) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def init(_args) do
    allocate_genesis_unspent_outputs()

    TransactionChain.list_all(@query_fields)
    |> Stream.each(&load_transaction/1)
    |> Stream.run()

    {:ok, []}
  end

  defp allocate_genesis_unspent_outputs do
    UCOLedger.add_unspent_output(Bootstrap.genesis_unspent_output_address(), %UnspentOutput{
      from: Bootstrap.genesis_unspent_output_address(),
      amount: Bootstrap.genesis_allocation()
    })
  end

  @doc """
  Load the transaction into the memory tables
  """
  @spec load_transaction(Transaction.t()) :: :ok
  def load_transaction(%Transaction{
        address: address,
        type: type,
        previous_public_key: previous_public_key,
        validation_stamp: %ValidationStamp{
          ledger_operations: %LedgerOperations{
            unspent_outputs: unspent_outputs,
            node_movements: node_movements,
            transaction_movements: transaction_movements
          }
        }
      }) do
    previous_public_key
    |> Crypto.hash()
    |> UCOLedger.spend_all_unspent_outputs()

    :ok = set_transaction_movements(address, transaction_movements)
    :ok = set_unspent_outputs(address, unspent_outputs)
    :ok = set_node_rewards(address, node_movements)

    Logger.info("Loaded into in memory account tables",
      transaction: "#{type}@#{Base.encode16(address)}"
    )
  end

  defp set_transaction_movements(address, transaction_movements) do
    Enum.each(
      transaction_movements,
      &UCOLedger.add_unspent_output(&1.to, %UnspentOutput{amount: &1.amount, from: address})
    )
  end

  defp set_unspent_outputs(address, unspent_outputs) do
    Enum.each(unspent_outputs, &UCOLedger.add_unspent_output(address, &1))
  end

  defp set_node_rewards(address, node_movements) do
    Enum.each(
      node_movements,
      &UCOLedger.add_unspent_output(Crypto.hash(&1.to), %UnspentOutput{
        amount: &1.amount,
        from: address
      })
    )
  end
end