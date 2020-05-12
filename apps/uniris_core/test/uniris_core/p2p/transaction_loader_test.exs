defmodule UnirisCore.P2P.TransactionLoaderTest do
  use UnirisCoreCase, async: false

  alias UnirisCore.Transaction
  alias UnirisCore.TransactionData
  alias UnirisCore.Crypto
  alias UnirisCore.P2P
  alias UnirisCore.P2P.Node
  alias UnirisCore.P2P.TransactionLoader

  import Mox

  setup do
    start_supervised!(UnirisCore.Storage.Cache)
    pid = start_supervised!({TransactionLoader, renewal_interval: 100})

    {:ok, %{pid: pid}}
  end

  test "start_link/1 should start the transaction loader and preload stored transactions" do
    {public_key, _} = Crypto.derivate_keypair("seed", 0)

    MockStorage
    |> expect(:node_transactions, fn ->
      [
        Transaction.new(
          :node,
          %TransactionData{
            content: """
            ip: 127.0.0.1
            port: 3000
            """
          },
          "seed",
          0
        )
      ]
    end)
    |> expect(:get_last_node_shared_secrets_transaction, fn ->
      auth_keys = %{} |> Map.put(public_key, "")

      {:ok,
       Transaction.new(:node_shared_secrets, %TransactionData{
         keys: %{
           authorized_keys: auth_keys
         }
       })}
    end)

    TransactionLoader.start_link([])
    Process.sleep(100)
    assert [%Node{first_public_key: public_key, authorized?: true}] = P2P.list_nodes()
  end

  test "when get {:new_transaction, %Transaction{type: node} should add the node in the system",
       %{pid: pid} do
    tx = Transaction.new(:node, %TransactionData{content: "ip: 127.0.0.1\nport: 3000"}, "seed", 0)

    send(pid, {:new_transaction, tx})
    Process.sleep(100)
    assert length(P2P.list_nodes()) == 1
  end

  test "when get {:new_transaction, %Transaction{type: node} should update the node if the previous transaction exists",
       %{pid: pid} do
    {pub, _} = Crypto.derivate_keypair("seed", 0)

    tx = Transaction.new(:node, %TransactionData{content: "ip: 127.0.0.1\nport: 3000"}, "seed", 0)

    send(pid, {:new_transaction, tx})
    Process.sleep(100)

    assert {:ok, %Node{port: 3000}} = P2P.node_info(pub)

    MockStorage
    |> expect(:get_transaction, fn _ ->
      {:ok, tx}
    end)

    tx = Transaction.new(:node, %TransactionData{content: "ip: 127.0.0.1\nport: 5000"}, "seed", 1)

    send(pid, {:new_transaction, tx})
    Process.sleep(100)

    assert {:ok, %Node{port: 5000}} = P2P.node_info(pub)
  end

  test "when get {:new_transaction, %Transaction{type: :node_shared_secrets} authorize the nodes after the renewal interval time",
       %{pid: pid} do
    P2P.add_node(%Node{
      ip: {127, 0, 0, 1},
      port: 3000,
      last_public_key: Crypto.node_public_key(),
      first_public_key: Crypto.node_public_key()
    })

    auth_keys = %{} |> Map.put(Crypto.node_public_key(), "")

    tx =
      Transaction.new(:node_shared_secrets, %TransactionData{
        keys: %{
          authorized_keys: auth_keys
        }
      })

    send(pid, {:new_transaction, tx})
    Process.sleep(200)

    assert {:ok, %Node{authorized?: true}} = P2P.node_info(Crypto.node_public_key())
  end
end