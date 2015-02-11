# encoding: ascii-8bit

require_relative '../spec_helper'
require_relative '../helpers/fake_blockchain'
require 'benchmark'

[
  [:utxo, :sqlite, db: :benchmark],
  [:utxo, :postgres],
  [:utxo, :mysql],
  [:archive, :sqlite, db: :benchmark],
  [:archive, :postgres],
  [:archive, :mysql],
].compact.each do |backend_name, adapter_name, conf = {}|

  Bitcoin.network = :fake

  def benchmark after_cb = nil
    res = []
    @fake_chain.blocks do |blk,i|
      res << Benchmark.measure { yield blk, i }
      after_cb.call(blk, i)  if after_cb
    end
    print res.inject(:+).format.strip
    print " - size: " + @store.database_size.to_s.reverse.gsub(/...(?=.)/,'\&.').reverse
  end

  describe "#{backend_name}:#{adapter_name}" do

    before do
      next  unless @store = setup_db(backend_name, adapter_name, { mempool: { require_fee: false }}.merge(conf))
      @store.log.level = :warn
      @fake_chain = FakeBlockchain.new 10, block_size: 1_000
    end

    after { close_db @store }

    it "validate block" do
      benchmark(->(b, i) { @store.new_block(b) }) do |blk, i|
        blk.validator(@store).validate.should == (i > 0) # genesis isn't validated
      end
    end

    it "store block without validation" do
      @store.config[:skip_validation] = true
      benchmark do |blk, i|
        depth, chain = @store.new_block blk
        chain.should == 0
      end
      @store.config[:skip_validation] = false
    end

    it "store block with validation" do
      benchmark do |blk, i|
        depth, chain = @store.new_block blk
        chain.should == 0
      end
    end

    it "insert transactions into mempool" do
      puts
      res = []
      @fake_chain.blocks do |blk,i|
        res << Benchmark.measure do |b|
          blk.tx[1..-1].each.with_index {|tx, i| @store.mempool.add(tx).should == i+1 }
        end
        @store.store_block(blk)
      end
      puts res.inject(:+).format
    end

    it "store block with transactions in mempool" do
      puts
      res = []
      @fake_chain.blocks do |blk,i|
        blk.tx[1..-1].each.with_index {|tx, i| @store.mempool.add(tx).should == i+1 }
        res << Benchmark.measure do |b|
          @store.new_block(blk).should == [i, 0]
         end
       end
      puts res.inject(:+).format
     end

  end
end
