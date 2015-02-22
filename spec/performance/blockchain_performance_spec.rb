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
      next  unless @store = setup_db(backend_name, adapter_name, conf)
      @store.log.level = :warn
      @fake_chain = FakeBlockchain.new 10, block_size: 1_000_000
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

  end
end
