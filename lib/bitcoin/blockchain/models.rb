# encoding: ascii-8bit

# Models defines objects that are returned from storage.
# These objects inherit from their {Bitcoin::Protocol} counterpart
# and add some additional data and methods.
#
# * {Bitcoin::Blockchain::Models::Block}
# * {Bitcoin::Blockchain::Models::Tx}
# * {Bitcoin::Blockchain::Models::TxIn}
# * {Bitcoin::Blockchain::Models::TxOut}
module Bitcoin::Blockchain::Models

  # Block retrieved from storage. (extends {Bitcoin::Protocol::Block})
  class Block < Bitcoin::Protocol::Block

    attr_accessor :ver, :prev_block_hash, :mrkl_root, :time, :bits, :nonce, :tx
    attr_reader :store, :id, :height, :chain, :work, :size

    def initialize store, data
      @store = store
      @id = data[:id]
      @height = data[:height]
      @chain = data[:chain]
      @work = data[:work]
      @size = data[:size]
      @tx = []
    end

    # get the block this one builds upon
    def prev_block
      @store.get_block(@prev_block_hash.reverse_hth)
    end
    alias :get_prev_block :prev_block

    # get the block that builds upon this one
    def next_block
      @store.block_by_prev_hash(@hash)
    end
    alias :get_next_block :next_block

    def total_out
      @total_out ||= tx.inject(0){ |m,t| m + t.total_out }
    end

    def total_in
      @total_in ||= tx.inject(0){ |m,t| m + t.total_in }
    end

    def total_fee
      @total_fee ||= tx.inject(0){ |m,t| m + t.fee }
    end

    def depth; @height; end

    # add :with_next_block option to add a reference to the next block (if any)
    def to_hash options = {}
      hash = super(options)
      if options[:with_next_block] && nb = next_block
        hash["next_block"] = nb.hash
      end
      hash
    end

  end

  # Transaction retrieved from storage. (extends {Bitcoin::Protocol::Tx})
  class Tx < Bitcoin::Protocol::Tx

    attr_accessor :ver, :lock_time, :hash
    attr_reader :store, :id, :blk_id, :size, :idx

    def initialize store, data
      @store = store
      @id = data[:id]
      @blk_id = data[:blk_id]
      @size = data[:size]
      @idx  = data[:idx]
      super(nil)
    end

    # get the block this transaction is in
    def block
      return nil  unless @blk_id
      @block ||= @store.block_by_id(@blk_id)
    end
    alias :get_block :block

    # get the number of blocks that confirm this tx in the main chain
    def confirmations
      return 0  unless @blk_id
      @store.height - @store.height_for_block_id(@blk_id) + 1
    end

    def total_out
      @total_out ||= self.out.inject(0){ |e, o| e + o.value }
    end

    # if tx_in is coinbase, set in value as total_out, fee could be 0
    def total_in
      @total_in ||= self.in.inject(0){ |m, input|
        m + (input.coinbase? ? total_out : (input.prev_out.try(:value) || 0))
      }
    end

    def fee
      @fee ||= total_in - total_out
    end
  end

  # Transaction input retrieved from storage. (extends {Bitcoin::Protocol::TxIn})
  class TxIn < Bitcoin::Protocol::TxIn

    attr_reader :store, :id, :tx_id, :tx_idx, :p2sh_type

    def initialize store, data
      @store = store
      @id = data[:id]
      @tx_id = data[:tx_id]
      @tx_idx = data[:tx_idx]
      @p2sh_type = data[:p2sh_type]
    end

    # get the transaction this input is in
    def tx
      @tx ||= @store.tx_by_id(@tx_id)
    end
    alias :get_tx :tx

    # get the previous output referenced by this input
    def prev_out
      @prev_tx_out ||= begin
        prev_tx = @store.tx(@prev_out_hash.reverse_hth)
        return nil  unless prev_tx
        prev_tx.out[@prev_out_index]
      end
    end
    alias :get_prev_out :prev_out

  end

  # Transaction output retrieved from storage. (extends {Bitcoin::Protocol::TxOut})
  class TxOut < Bitcoin::Protocol::TxOut

    attr_reader :store, :id, :tx_id, :tx_idx, :type

    def initialize store, data
      @store = store
      @id = data[:id]
      @tx_id = data[:tx_id]
      @tx_idx = data[:tx_idx]
      @type = data[:type]
    end

    def hash160
      parsed_script.get_hash160
    end

    # get the transaction this output is in
    def tx
      @tx ||= @store.tx_by_id(@tx_id)
    end
    alias :get_tx :tx

    # get the next input that references this output
    def next_in
      @store.txin_for_txout(tx.hash, @tx_idx)
    end
    alias :get_next_in :next_in

    # get all addresses this txout corresponds to (if possible)
    def address
      parsed_script.get_address
    end
    alias :get_address :address

    # get the single address this txout corresponds to (first for multisig tx)
    def addresses
      parsed_script.get_addresses
    end
    alias :get_addresses :addresses

    def namecoin_name
      @store.name_by_txout_id(@id)
    end
    alias :get_namecoin_name :namecoin_name

    def type
      parsed_script.type
    end

    # add :with_next_in option to add a reference to the next input (if any)
    def to_hash options = {}
      hash = super(options)
      if options[:with_next_in] && ni = next_in
        hash["next_in"] = { "hash" => ni.tx.hash, "n" => ni.tx_idx }
      end
      hash
    end
  end

end
