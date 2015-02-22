Sequel.migration do

  up do

    @log.info { "Running migration #{__FILE__}" }

    # rename the old column
    rename_column :utxo, :tx_hash, :tx_hash_tmp

    # create our new column (but without constraints/indexes yet)
    add_column :utxo, :tx_hash, (adapter_scheme == :postgres ? :bytea : :blob)

    # copy over existing data
    self[:utxo].each do |utxo|
      self[:utxo].where(id: utxo[:id]).update(tx_hash: utxo[:tx_hash_tmp].htb.blob)
    end

    # remove the temporary column
    drop_column :utxo, :tx_hash_tmp

    # add unique index for [tx_hash, tx_idx] pair
    unless indexes(:utxo)[:utxo_tx_hash_tx_idx_index]
      add_index :utxo, [:tx_hash, :tx_idx]
    end

    # add not null constraint for tx_hash
    alter_table(:utxo) do
      set_column_not_null :tx_hash
    end

  end

end
