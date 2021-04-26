defmodule Uniris.Mining.PendingTransactionValidationTest do
  use UnirisCase, async: false

  alias Uniris.Crypto
  alias Uniris.Crypto.KeystoreCounter

  alias Uniris.Governance.Pools.MemTable, as: PoolsMemTable

  alias Uniris.Mining.PendingTransactionValidation

  alias Uniris.P2P
  alias Uniris.P2P.Message.FirstPublicKey
  alias Uniris.P2P.Message.GetFirstPublicKey
  alias Uniris.P2P.Node

  alias Uniris.TransactionChain.Transaction
  alias Uniris.TransactionChain.TransactionData
  alias Uniris.TransactionChain.TransactionData.Keys

  import Mox

  setup do
    P2P.add_node(%Node{first_public_key: Crypto.node_public_key(), network_patch: "AAA"})
    :ok
  end

  describe "validate_pending_transaction/1" do
    test "should :ok when a node transaction data content contains node endpoint information" do
      tx =
        Transaction.new(
          :node,
          %TransactionData{
            content: """
            ip: 127.0.0.1
            port: 3000
            transport: tcp
            reward address: 00A3EDE95D0EF1F10890DA69108AF3DF11B65709073592AE7D05F42A23D18E18A4
            """
          },
          "seed",
          0
        )

      assert :ok = PendingTransactionValidation.validate(tx)
    end

    test "should return :ok when a node shared secrets transaction data keys contains existing node public keys with first tx" do
      MockDB
      |> expect(:list_transactions_by_type, fn
        :node_shared_secrets, _ ->
          []
      end)

      P2P.add_node(%Node{
        ip: {127, 0, 0, 1},
        port: 3000,
        first_public_key: "node_key1",
        last_public_key: "node_key1",
        available?: true
      })

      P2P.add_node(%Node{
        ip: {127, 0, 0, 1},
        port: 3000,
        first_public_key: "node_key2",
        last_public_key: "node_key2",
        available?: true
      })

      tx =
        Transaction.new(
          :node_shared_secrets,
          %TransactionData{
            keys: %Keys{
              secret: :crypto.strong_rand_bytes(32),
              authorized_keys: %{
                "node_key1" => "",
                "node_key2" => ""
              }
            }
          }
        )

      assert :ok = PendingTransactionValidation.validate(tx)
    end

    test "should return :ok when a node shared secrets transaction data keys contains existing node public keys with next tx" do
      prev_address1 =
        Crypto.hash(
          Crypto.node_shared_secrets_public_key(Crypto.number_of_node_shared_secrets_keys())
        )

      prev_address2 =
        Crypto.hash(
          Crypto.node_shared_secrets_public_key(Crypto.number_of_node_shared_secrets_keys() + 1)
        )

      MockDB
      |> expect(:list_transactions_by_type, fn
        :node_shared_secrets, _ ->
          [
            %Transaction{
              address: prev_address2,
              type: :node_shared_secrets
            },
            %Transaction{
              address: prev_address1,
              type: :node_shared_secrets
            }
          ]
      end)

      P2P.add_node(%Node{
        ip: {127, 0, 0, 1},
        port: 3000,
        first_public_key: "node_key1",
        last_public_key: "node_key1",
        available?: true
      })

      P2P.add_node(%Node{
        ip: {127, 0, 0, 1},
        port: 3000,
        first_public_key: "node_key2",
        last_public_key: "node_key2",
        available?: true
      })

      KeystoreCounter.set_node_shared_secrets_key_counter(1)

      tx =
        Transaction.new(
          :node_shared_secrets,
          %TransactionData{
            keys: %Keys{
              secret: :crypto.strong_rand_bytes(32),
              authorized_keys: %{
                "node_key1" => "",
                "node_key2" => ""
              }
            }
          }
        )

      assert :ok = PendingTransactionValidation.validate(tx)
    end

    test "should return :ok when a code approval transaction contains a proposal target and the sender is member of the technical council and not previously signed" do
      tx =
        Transaction.new(
          :code_approval,
          %TransactionData{
            recipients: ["@CodeProposal1"]
          },
          "approval_seed",
          0
        )

      P2P.add_node(%Node{
        ip: {127, 0, 0, 1},
        port: 3000,
        first_public_key: "node1",
        last_public_key: "node1",
        geo_patch: "AAA",
        network_patch: "AAA",
        available?: true
      })

      assert :ok = PoolsMemTable.put_pool_member(:technical_council, tx.previous_public_key)

      MockDB
      |> expect(:get_transaction, fn _, _ ->
        {:ok,
         %Transaction{
           data: %TransactionData{
             content: """
             Description: My Super Description
             Changes:
             diff --git a/mix.exs b/mix.exs
             index d9d9a06..5e34b89 100644
             --- a/mix.exs
             +++ b/mix.exs
             @@ -4,7 +4,7 @@ defmodule Uniris.MixProject do
               def project do
                 [
                   app: :uniris,
             -      version: \"0.7.1\",
             +      version: \"0.7.2\",
                   build_path: \"_build\",
                   config_path: \"config/config.exs\",
                   deps_path: \"deps\",
             @@ -53,7 +53,7 @@ defmodule Uniris.MixProject do
                   {:git_hooks, \"~> 0.4.0\", only: [:test, :dev], runtime: false},
                   {:mox, \"~> 0.5.2\", only: [:test]},
                   {:stream_data, \"~> 0.4.3\", only: [:test]},
             -      {:elixir_make, \"~> 0.6.0\", only: [:dev, :test], runtime: false},
             +      {:elixir_make, \"~> 0.6.0\", only: [:dev, :test]},
                   {:logger_file_backend, \"~> 0.0.11\", only: [:dev]}
                 ]
               end
             """
           }
         }}
      end)

      MockClient
      |> expect(:send_message, fn _, %GetFirstPublicKey{} ->
        {:ok, %FirstPublicKey{public_key: tx.previous_public_key}}
      end)

      assert :ok = PendingTransactionValidation.validate(tx)
    end

    test "should return :ok when a transaction contains a valid smart contract code" do
      tx_seed = :crypto.strong_rand_bytes(32)

      tx =
        Transaction.new(
          :transfer,
          %TransactionData{
            code: """
            condition inherit,
              content: "hello"

            actions triggered_by: transaction do
              set_content "hello"
            end
            """,
            keys:
              Keys.new(
                [Crypto.storage_nonce_public_key()],
                :crypto.strong_rand_bytes(32),
                tx_seed
              )
          },
          tx_seed,
          0
        )

      assert :ok = PendingTransactionValidation.validate(tx)
    end
  end
end