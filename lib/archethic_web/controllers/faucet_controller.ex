defmodule ArchethicWeb.FaucetController do
  @moduledoc false

  use ArchethicWeb, :controller

  alias Archethic.Crypto

  alias Archethic.TransactionChain.{
    Transaction,
    TransactionData,
    TransactionData.Ledger,
    TransactionData.UCOLedger
  }

  alias Archethic.TransactionChain

  alias ArchethicWeb.TransactionSubscriber
  alias ArchethicWeb.FaucetRateLimiter

  @pool_seed Application.compile_env(:archethic, [__MODULE__, :seed])
  @faucet_rate_limit_expiry Application.compile_env(:archethic, :faucet_rate_limit_expiry)

  plug(:enabled)

  defp enabled(conn, _) do
    if Application.get_env(:archethic, __MODULE__)
       |> Keyword.get(:enabled, false) do
      conn
    else
      conn
      |> put_status(:not_found)
      |> put_view(ArchethicWeb.ErrorView)
      |> render("404.html")
      |> halt()
    end
  end

  def index(conn, __params) do
    conn
    |> put_resp_header("cache-control", "no-cache, no-store, must-revalidate")
    |> put_resp_header("pragma", "no-cache")
    |> put_resp_header("expires", "0")
    |> render("index.html", address: "", link_address: "")
  end

  def create_transfer(conn, %{"address" => address}) do
    with {:ok, recipient_address} <- Base.decode16(address, case: :mixed),
         true <- Crypto.valid_address?(recipient_address),
         %{blocked?: false} <- FaucetRateLimiter.get_address_block_status(address),
         {:ok, tx_address} <- transfer(recipient_address) do
      TransactionSubscriber.register(tx_address, System.monotonic_time())

      conn
      |> put_resp_header("cache-control", "no-cache, no-store, must-revalidate")
      |> put_resp_header("pragma", "no-cache")
      |> put_resp_header("expires", "0")
      |> put_flash(:info, "Transaction submitted (click to see it)")
      |> render("index.html", address: "", link_address: Base.encode16(tx_address))
    else
      {:error, _} ->
        conn
        |> put_flash(:error, "Unable to send the transaction")
        |> render("index.html", address: address, link_address: "")

      %{blocked?: true, blocked_since: blocked_since} ->
        now = System.monotonic_time()
        blocked_elapsed_time = System.convert_time_unit(now - blocked_since, :native, :second)
        blocked_elapsed_diff = div(@faucet_rate_limit_expiry, 1000) - blocked_elapsed_time

        conn
        |> put_flash(
          :error,
          "Blocked address as you exceeded usage limit of UCO temporarily. Try after #{Archethic.Utils.seconds_to_human_readable(blocked_elapsed_diff)}"
        )
        |> render("index.html", address: address, link_address: "")

      _ ->
        conn
        |> put_flash(:error, "Malformed address")
        |> render("index.html", address: address, link_address: "")
    end
  end

  def transaction_confirmed({_, tx_address}) do
    address =
      case TransactionChain.get_transaction(tx_address) do
        {:ok,
         %Archethic.TransactionChain.Transaction{
           data: %Archethic.TransactionChain.TransactionData{
             ledger: %Archethic.TransactionChain.TransactionData.Ledger{
               uco: %Archethic.TransactionChain.TransactionData.UCOLedger{
                 transfers: [
                   %Archethic.TransactionChain.TransactionData.UCOLedger.Transfer{
                     amount: 10_000_000_000,
                     to: address
                   }
                 ]
               }
             }
           }
         }} ->
          address

        _ ->
          tx_address
      end

    #  How to get user's address from tx_address
    FaucetRateLimiter.register(address, System.monotonic_time())
  end

  defp transfer(
         recipient_address,
         curve \\ Crypto.default_curve()
       )
       when is_bitstring(recipient_address) do
    {gen_pub, _} = Crypto.derive_keypair(@pool_seed, 0, curve)

    pool_gen_address = Crypto.derive_address(gen_pub)

    with {:ok, last_address} <-
           Archethic.get_last_transaction_address(pool_gen_address),
         {:ok, last_index} <- Archethic.get_transaction_chain_length(last_address) do
      create_transaction(last_index, curve, recipient_address)
    else
      {:error, _} = e ->
        e
    end
  end

  defp create_transaction(transaction_index, curve, recipient_address) do
    tx =
      Transaction.new(
        :transfer,
        %TransactionData{
          ledger: %Ledger{
            uco: %UCOLedger{
              transfers: [
                %UCOLedger.Transfer{
                  to: recipient_address,
                  amount: 10_000_000_000
                }
              ]
            }
          }
        },
        @pool_seed,
        transaction_index,
        curve
      )

    case Archethic.send_new_transaction(tx) do
      :ok ->
        {:ok, tx.address}

      {:error, _} = e ->
        e
    end
  end
end
