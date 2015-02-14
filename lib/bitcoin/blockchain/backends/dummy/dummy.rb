require 'sequel'

module Bitcoin::Blockchain::Backends
  class Dummy < Base

    attr_accessor :blk, :tx

    def initialize config
      reset
      super(config)
    end

    def reset
      @blk, @tx = [], {}
    end

    def persist_block(blk, chain, height, prev_work = 0)
      return [height, chain]  unless blk && chain == 0
      if block = block(blk.hash)
        log.info { "Block already stored; skipping" }
        return false
      end

      blk.tx.each {|tx| store_tx(tx) }
      @blk << blk

      log.info { "NEW HEAD: #{blk.hash} HEIGHT: #{height}" }
      [height, chain]
    end

    def store_tx(tx, validate = true)
      if @tx.keys.include?(tx.hash)
        log.info { "Tx already stored; skipping" }
        return tx
      end
      @tx[tx.hash] = tx
    end

    def has_block(blk_hash)
      !!block(blk_hash)
    end

    def has_tx(tx_hash)
      !!tx(tx_hash)
    end

    def height
      @blk.size - 1
    end
    alias :get_depth :height

    def head
      wrap_block(@blk[-1])
    end
    alias :get_head :head

    def block_at_height(height)
      wrap_block(@blk[height])
    end
    alias :get_block_by_depth :block_at_height


    def block_by_prev_hash(hash)
      wrap_block(@blk.find {|blk| blk.prev_block == [hash].pack("H*").reverse})
    end
    alias :get_block_by_prev_hash :block_by_prev_hash

    def block(blk_hash)
      wrap_block(@blk.find {|blk| blk.hash == blk_hash})
    end
    alias :get_block :block

    def block_by_id(blk_id)
      wrap_block(@blk[blk_id])
    end
    alias :get_block_by_id :block_by_id

    def block_by_tx_hash(tx_hash)
      wrap_block(@blk.find {|blk| blk.tx.map(&:hash).include?(tx_hash) })
    end
    alias :block_by_tx :block_by_tx_hash
    alias :get_block_by_tx :block_by_tx_hash

    def idx_from_tx_hash(tx_hash)
      return nil unless tx = tx(tx_hash)
      return nil unless blk = tx.block
      blk.tx.index tx
    end
    alias :get_idx_from_tx_hash :idx_from_tx_hash

    def tx(tx_hash)
      transaction = @tx[tx_hash]
      return nil  unless transaction
      wrap_tx(transaction)
    end
    alias :get_tx :tx

    def tx_by_id(tx_id)
      wrap_tx(@tx[tx_id])
    end
    alias :get_tx_by_id :tx_by_id

    def txin_for_txout(tx_hash, txout_idx)
      txin = @tx.values.map(&:in).flatten.find {|i|
        i.prev_out_index == txout_idx &&
        i.prev_out == [tx_hash].pack("H*").reverse }
      wrap_txin(txin)
    end
    alias :get_txin_for_txout :txin_for_txout

    def txout_for_txin(txin)
      return nil unless tx = @tx[txin.prev_out_hash.reverse_hth]
      wrap_tx(tx).out[txin.prev_out_index]
    end
    alias :get_txout_for_txin :txout_for_txin

    def txouts_for_pk_script(script)
      txouts = @tx.values.map(&:out).flatten.select {|o| o.pk_script == script}
      txouts.map {|o| wrap_txout(o) }
    end
    alias :get_txouts_for_pk_script :txouts_for_pk_script

    def txouts_for_hash160(hash160, type = :hash160, unconfirmed = false)
      @tx.values.map(&:out).flatten.map {|o|
        o = wrap_txout(o)
        if o.parsed_script.is_multisig?
          o.parsed_script.get_multisig_pubkeys.map{|pk| Bitcoin.hash160(pk.unpack("H*")[0])}.include?(hash160) ? o : nil
        else
          o.hash160 == hash160 && o.type == type ? o : nil
        end
      }.compact
    end
    alias :get_txouts_for_hash160 :txouts_for_hash160

    def wrap_block(block)
      return nil  unless block
      data = { id: @blk.index(block), height: @blk.index(block),
        work: @blk.index(block), chain: MAIN, size: block.size }
      blk = Bitcoin::Blockchain::Models::Block.new(self, data)
      [:ver, :prev_block_hash, :mrkl_root, :time, :bits, :nonce].each do |attr|
        blk.send("#{attr}=", block.send(attr))
      end
      block.tx.each do |tx|
        blk.tx << tx(tx.hash)
      end
      blk.recalc_block_hash
      blk
    end

    def wrap_tx(transaction)
      return nil  unless transaction
      blk = @blk.find{|b| b.tx.include?(transaction)}
      data = { id: transaction.hash, blk_id: @blk.index(blk), size: transaction.size }
      tx = Bitcoin::Blockchain::Models::Tx.new(self, data)
      tx.ver = transaction.ver
      tx.lock_time = transaction.lock_time
      transaction.in.each {|i| tx.add_in(wrap_txin(i))}
      transaction.out.each {|o| tx.add_out(wrap_txout(o))}
      tx.hash = tx.hash_from_payload(tx.to_payload)
      tx
    end

    def wrap_txin(input)
      return nil  unless input
      tx = @tx.values.find{|t| t.in.include?(input)}
      data = { tx_id: tx.hash, tx_idx: tx.in.index(input)}
      txin = Bitcoin::Blockchain::Models::TxIn.new(self, data)
      [:prev_out, :prev_out_index, :script_sig_length, :script_sig, :sequence].each do |attr|
        txin.send("#{attr}=", input.send(attr))
      end
      txin
    end

    def wrap_txout(output)
      return nil  unless output
      tx = @tx.values.find{|t| t.out.include?(output)}
      data = {tx_id: tx.hash, tx_idx: tx.out.index(output), hash160: output.parsed_script.get_hash160}
      txout = Bitcoin::Blockchain::Models::TxOut.new(self, data)
      [:value, :pk_script_length, :pk_script].each do |attr|
        txout.send("#{attr}=", output.send(attr))
      end
      txout
    end

    def to_s
      "DummyStore"
    end

    def check_consistency(*args)
      log.warn { "Dummy store doesn't support consistency check" }
    end


  end
end
