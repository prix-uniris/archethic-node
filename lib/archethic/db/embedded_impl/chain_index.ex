defmodule ArchEthic.DB.EmbeddedImpl.ChainIndex do
  @moduledoc """
  Manage the indexing of the transaction chains for both file and memory storage
  """

  use GenServer

  alias ArchEthic.Crypto
  alias ArchEthic.DB.EmbeddedImpl.ChainWriter
  alias ArchEthic.TransactionChain.Transaction

  def start_link(arg \\ []) do
    GenServer.start_link(__MODULE__, arg, name: __MODULE__)
  end

  def init(opts) do
    db_path = Keyword.fetch!(opts, :path)

    :ets.new(:archethic_db_tx_index, [:set, :named_table, :public, read_concurrency: true])
    :ets.new(:archethic_db_chain_stats, [:set, :named_table, :public, read_concurrency: true])
    :ets.new(:archethic_db_last_index, [:set, :named_table, :public, read_concurrency: true])
    :ets.new(:archethic_db_type_stats, [:set, :named_table, :public, read_concurrency: true])

    :ets.new(:archethic_db_bloom_filters, [:set, :named_table, :public, read_concurrency: true])

    fill_tables(db_path)

    {:ok, %{db_path: db_path}}
  end

  defp fill_tables(db_path) do
    Enum.each(0..255, fn subset ->
      bloom_filter = BloomFilter.new(256, 0.001)
      :ets.insert(:archethic_db_bloom_filters, {subset, bloom_filter})
      subset_summary_filename = index_summary_path(db_path, subset)
      scan_summary_table(subset_summary_filename)
    end)

    fill_type_stats(db_path)
  end

  defp scan_summary_table(filename) do
    case File.open(filename, [:binary, :read]) do
      {:ok, fd} ->
        do_scan_summary_table(fd)

      {:error, _} ->
        :ok
    end
  end

  defp do_scan_summary_table(fd) do
    with {:ok, <<current_curve_id::8, current_hash_type::8>>} <- :file.read(fd, 2),
         hash_size <- Crypto.hash_size(current_hash_type),
         {:ok, current_digest} <- :file.read(fd, hash_size),
         {:ok, <<genesis_curve_id::8, genesis_hash_type::8>>} <- :file.read(fd, 2),
         hash_size <- Crypto.hash_size(genesis_hash_type),
         {:ok, genesis_digest} <- :file.read(fd, hash_size),
         {:ok, <<size::32, offset::32>>} <- :file.read(fd, 8) do
      current_address = <<current_curve_id::8, current_hash_type::8, current_digest::binary>>
      genesis_address = <<genesis_curve_id::8, genesis_hash_type::8, genesis_digest::binary>>

      # Fill the bloom filters
      <<subset::8, address_digest::binary>> = current_digest
      [{_, bloom_filter}] = :ets.lookup(:archethic_db_bloom_filters, subset)
      bloom_filter = BloomFilter.add(bloom_filter, address_digest)
      :ets.insert(:archethic_db_bloom_filters, {subset, bloom_filter})

      # Register last addresses of genesis address
      true = :ets.insert(:archethic_db_last_index, {genesis_address, current_address})

      true =
        :ets.insert(
          :archethic_db_tx_index,
          {current_address, %{size: size, offset: offset, genesis_address: genesis_address}}
        )

      :ets.update_counter(
        :archethic_db_chain_stats,
        genesis_address,
        [
          {2, size},
          {3, 1}
        ],
        {genesis_address, 0, 0}
      )

      do_scan_summary_table(fd)
    else
      :eof ->
        :file.close(fd)
        nil
    end
  end

  defp fill_type_stats(db_path) do
    Enum.each(Transaction.types(), fn type ->
      case File.open(type_path(db_path, type), [:read, :binary]) do
        {:ok, fd} ->
          nb_txs = do_scan_types(fd)
          :ets.insert(:archethic_db_type_stats, {type, nb_txs})

        {:error, _} ->
          :ets.insert(:archethic_db_type_stats, {type, 0})
      end
    end)
  end

  defp do_scan_types(fd, acc \\ 0) do
    with {:ok, <<_curve_id::8, hash_id::8>>} <- :file.read(fd, 2),
         hash_size <- Crypto.hash_size(hash_id),
         {:ok, _digest} <- :file.read(fd, hash_size) do
      do_scan_types(fd, acc + 1)
    else
      :eof ->
        :file.close(fd)
        acc
    end
  end

  @doc """
  Add transaction indexing inserting lookup back on file and on memory for fast lookup by genesis
  """
  @spec add_tx(binary(), binary(), non_neg_integer(), db_path :: String.t()) :: :ok
  def add_tx(
        tx_address = <<_::8, _::8, subset::8, digest::binary>>,
        genesis_address,
        size,
        db_path
      ) do
    {last_offset, _nb_txs} = get_file_stats(genesis_address)

    # Write the transaction lookup in the subset index
    File.write!(
      index_summary_path(db_path, subset),
      <<tx_address::binary, genesis_address::binary, size::32, last_offset::32>>,
      [:binary, :append]
    )

    # Write fast lookup entry for this transaction on memory
    true =
      :ets.insert(
        :archethic_db_tx_index,
        {tx_address, %{size: size, offset: last_offset, genesis_address: genesis_address}}
      )

    :ets.update_counter(
      :archethic_db_chain_stats,
      genesis_address,
      [
        {2, size},
        {3, 1}
      ],
      {genesis_address, 0, 0}
    )

    [{_, bloom_filter}] = :ets.lookup(:archethic_db_bloom_filters, subset)
    bloom_filter = BloomFilter.add(bloom_filter, digest)
    :ets.insert(:archethic_db_bloom_filters, {subset, bloom_filter})

    :ok
  end

  @spec get_file_stats(binary()) ::
          {offset :: non_neg_integer(), nb_transactions :: non_neg_integer()}
  def get_file_stats(genesis_address) do
    case :ets.lookup(:archethic_db_chain_stats, genesis_address) do
      [{_, last_offset, nb_txs}] ->
        {last_offset, nb_txs}

      [] ->
        {0, 0}
    end
  end

  @doc """
  Return the size of a given transaction chain
  """
  @spec chain_size(binary(), String.t()) :: non_neg_integer()
  def chain_size(address, db_path) do
    # Get the genesis address for the given transaction's address
    case get_tx_entry(address, db_path) do
      {:ok, %{genesis_address: genesis_address}} ->
        # Get the chain file stats including the nb of transactions written
        {_, nb_txs} = get_file_stats(genesis_address)
        nb_txs

      {:error, :not_exists} ->
        0
    end
  end

  @doc """
  Determine if a transaction exists
  """
  @spec transaction_exists?(binary()) :: boolean()
  def transaction_exists?(address = <<_::8, _::8, subset::8, digest::binary>>) do
    [{_, bloom_filter}] = :ets.lookup(:archethic_db_bloom_filters, subset)
    :ets.member(:archethic_db_tx_index, address) or BloomFilter.has?(bloom_filter, digest)
  end

  @doc """
  Get transaction file entry
  """
  @spec get_tx_entry(binary(), String.t()) :: {:ok, map()} | {:error, :not_exists}
  def get_tx_entry(address, db_path) do
    case :ets.lookup(:archethic_db_tx_index, address) do
      [] ->
        # If the transaction is not found in the in memory lookup
        # we scan the index file for the subset of the transaction to find the relative information
        search_tx_entry(address, db_path)

      [{_address, entry}] ->
        {:ok, entry}
    end
  end

  defp search_tx_entry(search_address = <<_::8, _::8, digest::binary>>, db_path) do
    <<subset::8, _::binary>> = digest
    [{_, bloom_filter}] = :ets.lookup(:archethic_db_bloom_filters, subset)

    with true <- BloomFilter.has?(bloom_filter, digest),
         {:ok, fd} <- File.open(index_summary_path(db_path, subset), [:binary, :read]) do
      case do_search_tx_entry(fd, search_address) do
        nil ->
          :file.close(fd)
          {:error, :not_exists}

        {genesis_address, size, offset} ->
          :file.close(fd)
          {:ok, %{genesis_address: genesis_address, size: size, offset: offset}}
      end
    else
      false ->
        {:error, :not_exists}

      {:error, _} ->
        {:error, :not_exists}
    end
  end

  defp do_search_tx_entry(fd, search_address) do
    # We need to extract hash metadata information to know how many bytes to decode
    # as hashes can have different sizes based on the algorithm used
    with {:ok, <<current_curve_id::8, current_hash_type::8>>} <- :file.read(fd, 2),
         hash_size <- Crypto.hash_size(current_hash_type),
         {:ok, current_digest} <- :file.read(fd, hash_size),
         {:ok, <<genesis_curve_id::8, genesis_hash_type::8>>} <- :file.read(fd, 2),
         hash_size <- Crypto.hash_size(genesis_hash_type),
         {:ok, genesis_digest} <- :file.read(fd, hash_size),
         {:ok, <<size::32, offset::32>>} <- :file.read(fd, 8) do
      current_address = <<current_curve_id::8, current_hash_type::8, current_digest::binary>>

      # If it's the address we are looking for, we return the genesis address 
      # and the chain file seeking information
      if current_address == search_address do
        genesis_address = <<genesis_curve_id::8, genesis_hash_type::8, genesis_digest::binary>>
        {genesis_address, size, offset}
      else
        do_search_tx_entry(fd, search_address)
      end
    else
      :eof ->
        nil
    end
  end

  @doc """
  Stream all the transaction addresses for a given type
  """
  @spec get_addresses_by_type(Transaction.transaction_type(), String.t()) :: Enumerable.t()
  def get_addresses_by_type(type, db_path) do
    Stream.resource(
      fn -> File.open(type_path(db_path, type), [:read, :binary]) end,
      fn
        {:error, _} ->
          {:halt, nil}

        {:ok, fd} ->
          # We need to extract hash metadata information to know how many bytes to decode
          # as hashes can have different sizes based on the algorithm used
          with {:ok, <<curve_id::8, hash_id::8>>} <- :file.read(fd, 2),
               hash_size <- Crypto.hash_size(hash_id),
               {:ok, digest} <- :file.read(fd, hash_size) do
            address = <<curve_id::8, hash_id::8, digest::binary>>
            {[address], {:ok, fd}}
          else
            :eof ->
              {:halt, {:ok, fd}}
          end
      end,
      fn
        nil -> :ok
        {:ok, fd} -> :file.close(fd)
      end
    )
  end

  @doc """
  Return the number of transactions for a given type
  """
  @spec count_transactions_by_type(Transaction.transaction_type()) :: non_neg_integer()
  def count_transactions_by_type(type) do
    case :ets.lookup(:archethic_db_type_stats, type) do
      [] ->
        0

      [{_, nb}] ->
        nb
    end
  end

  @doc """
  Insert transaction's address for a given transaction's type in its corresponding file
  """
  @spec add_tx_type(Transaction.transaction_type(), binary(), String.t()) ::
          :ok
  def add_tx_type(type, address, db_path) do
    File.write!(type_path(db_path, type), address, [:append, :binary])
    :ets.update_counter(:archethic_db_type_stats, type, {2, 1}, {type, 0})
    :ok
  end

  @doc """
  Reference a new transaction address for the previous address at the transaction time

  This will perform a lookup to find out the genesis address from the previous address
  and set the new address as reference
  """
  @spec set_last_chain_address(binary(), binary(), DateTime.t(), String.t()) :: :ok
  def set_last_chain_address(
        previous_address,
        new_address,
        datetime = %DateTime{},
        db_path
      ) do
    unix_time = DateTime.to_unix(datetime)

    encoded_data = <<unix_time::32, new_address::binary>>

    {filename, genesis_address} =
      case get_tx_entry(previous_address, db_path) do
        {:ok, %{genesis_address: genesis_address}} ->
          filename = chain_addresses_path(db_path, genesis_address)
          {filename, genesis_address}

        {:error, :not_exists} ->
          filename = chain_addresses_path(db_path, previous_address)
          {filename, previous_address}
      end

    :ok = File.write!(filename, encoded_data, [:binary, :append])
    true = :ets.insert(:archethic_db_last_index, {genesis_address, new_address})
    :ok
  end

  @doc """
  Return the last address of the chain
  """
  @spec get_last_chain_address(address :: binary(), db_path :: String.t()) :: binary()
  def get_last_chain_address(address, db_path) do
    # We try with a transaction on a chain, to identity the genesis address
    case get_tx_entry(address, db_path) do
      {:ok, %{genesis_address: genesis_address}} ->
        # Search in the latest in memory index
        case :ets.lookup(:archethic_db_last_index, genesis_address) do
          [] ->
            # If not present, the we search in the index file
            unix_time = DateTime.utc_now() |> DateTime.to_unix()

            search_last_address_until(genesis_address, unix_time, db_path) || address

          [{_, last_address}] ->
            last_address
        end

      {:error, :not_exists} ->
        # We try if the request address is the genesis address to fetch the in memory index
        case :ets.lookup(:archethic_db_last_index, address) do
          [] ->
            address

          [{_, last_address}] ->
            last_address
        end
    end
  end

  @doc """
  Return the last address of the chain before or equal to the given date
  """
  @spec get_last_chain_address(address :: binary(), until :: DateTime.t(), db_path :: String.t()) ::
          binary()
  def get_last_chain_address(address, datetime = %DateTime{}, db_path) do
    unix_time = DateTime.to_unix(datetime)

    # We get the genesis address of this given transaction address
    case get_tx_entry(address, db_path) do
      {:ok, %{genesis_address: genesis_address}} ->
        search_last_address_until(genesis_address, unix_time, db_path) || address

      {:error, :not_exists} ->
        # We try to search with given address as genesis address
        # Then `address` acts the genesis address
        search_last_address_until(address, unix_time, db_path) || address
    end
  end

  defp search_last_address_until(genesis_address, until, db_path) do
    filepath = chain_addresses_path(db_path, genesis_address)

    case File.open(filepath, [:binary, :read]) do
      {:ok, fd} ->
        do_search_last_address_until(fd, until)

      {:error, _} ->
        nil
    end
  end

  defp do_search_last_address_until(fd, until, acc \\ nil) do
    with {:ok, <<timestamp::32>>} <- :file.read(fd, 4),
         {:ok, <<curve_id::8, hash_id::8>>} <- :file.read(fd, 2),
         hash_size <- Crypto.hash_size(hash_id),
         {:ok, hash} <- :file.read(fd, hash_size) do
      address = <<curve_id::8, hash_id::8, hash::binary>>

      if timestamp < until do
        do_search_last_address_until(fd, until, address)
      else
        cond do
          timestamp == until ->
            :file.close(fd)
            address

          timestamp < until ->
            do_search_last_address_until(fd, until, address)

          true ->
            :file.close(fd)
            acc
        end
      end
    else
      :eof ->
        :file.close(fd)
        acc
    end
  end

  @doc """
  Return the first address of a chain

  If not address is found, the given address is returned
  """
  @spec get_first_chain_address(binary(), String.t()) :: binary()
  def get_first_chain_address(address, db_path) do
    case get_tx_entry(address, db_path) do
      {:ok, %{genesis_address: genesis_address}} ->
        genesis_address

      {:error, :not_exists} ->
        address
    end
  end

  @doc """
  Reference a new public key for the given genesis address
  """
  @spec set_public_key(binary(), Crypto.key(), DateTime.t(), String.t()) :: :ok
  def set_public_key(genesis_address, public_key, date = %DateTime{}, db_path) do
    unix_time = DateTime.to_unix(date)

    File.write!(
      chain_keys_path(db_path, genesis_address),
      <<unix_time::32, public_key::binary>>,
      [:binary, :append]
    )
  end

  @doc """
  Return the first public key of a chain by reading the genesis index file and capturing the first key

  If no key is found, the given public key is returned
  """
  @spec get_first_public_key(Crypto.key(), String.t()) :: Crypto.key()
  def get_first_public_key(public_key, db_path) do
    # We derive the previous address from the public key to get the genesis address
    # and its relative file
    address = Crypto.derive_address(public_key)
    genesis_address = get_first_chain_address(address, db_path)
    filepath = chain_keys_path(db_path, genesis_address)

    case File.open(filepath, [:binary, :read]) do
      {:ok, fd} ->
        # We need to extract key metadata information to know how many bytes to decode
        # as keys can have different sizes based on the curve used
        with {:ok, <<_timestamp::32, curve_id::8, origin_id::8>>} <- :file.read(fd, 6),
             key_size <- Crypto.key_size(curve_id),
             {:ok, key} <- :file.read(fd, key_size) do
          # We then take the first public key registered
          :file.close(fd)
          <<curve_id::8, origin_id::8, key::binary>>
        else
          :eof ->
            :file.close(fd)
            public_key
        end

      {:error, _} ->
        public_key
    end
  end

  @doc """
  Stream all the file stats entries to indentify the addresses
  """
  @spec list_all_addresses(String.t()) :: Enumerable.t() | list(binary())
  def list_all_addresses(db_path) do
    list_genesis_addresses()
    |> Stream.map(&scan_chain(&1, db_path))
    |> Stream.flat_map(& &1)
  end

  @doc """
  Stream all the genesis keys from the ETS file stats table
  """
  @spec list_genesis_addresses() :: Enumerable.t()
  def list_genesis_addresses do
    Stream.resource(
      fn -> [] end,
      &stream_genesis_addresses/1,
      fn _ -> :ok end
    )
  end

  defp stream_genesis_addresses(acc = []) do
    case :ets.first(:archethic_db_chain_stats) do
      :"$end_of_table" -> {:halt, acc}
      first_key -> {[first_key], first_key}
    end
  end

  defp stream_genesis_addresses(acc) do
    case :ets.next(:archethic_db_chain_stats, acc) do
      :"$end_of_table" -> {:halt, acc}
      next_key -> {[next_key], next_key}
    end
  end

  defp scan_chain(genesis_address, db_path) do
    filepath = chain_addresses_path(db_path, genesis_address)
    fd = File.open!(filepath, [:binary, :read])
    do_scan_chain(fd)
  end

  defp do_scan_chain(fd, acc \\ []) do
    with {:ok, <<_timestamp::32>>} <- :file.read(fd, 4),
         {:ok, <<curve_id::8, hash_id::8>>} <- :file.read(fd, 2),
         hash_size <- Crypto.hash_size(hash_id),
         {:ok, hash} <- :file.read(fd, hash_size) do
      address = <<curve_id::8, hash_id::8, hash::binary>>
      do_scan_chain(fd, [address | acc])
    else
      :eof ->
        :file.close(fd)
        acc
    end
  end

  defp index_summary_path(db_path, subset) do
    Path.join([ChainWriter.base_path(db_path), "#{Base.encode16(<<subset>>)}-summary"])
  end

  defp chain_addresses_path(db_path, genesis_address) do
    Path.join([ChainWriter.base_path(db_path), "#{Base.encode16(genesis_address)}-addresses"])
  end

  defp type_path(db_path, type) do
    Path.join([ChainWriter.base_path(db_path), Atom.to_string(type)])
  end

  defp chain_keys_path(db_path, genesis_address) do
    Path.join([ChainWriter.base_path(db_path), "#{Base.encode16(genesis_address)}-keys"])
  end
end