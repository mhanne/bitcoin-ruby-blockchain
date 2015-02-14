# encoding: ascii-8bit

require_relative '../spec_helper'
require_relative '../helpers/fake_blockchain'
require 'benchmark'

[
  [:archive, :postgres]
].compact.each do |options|

  Bitcoin.network = :fake

  next  unless storage = setup_db(*options)

  def benchmark after_cb = nil
    res = []
    @fake_chain.blocks do |blk,i|
      res << Benchmark.measure { yield blk, i }
      after_cb.call(blk, i)  if after_cb
    end
    puts res.inject(:+).format
  end

  describe "#{storage.backend_name} block storage" do

    before do
      @store = storage
      @store.reset
      @store.log.level = :warn
      @fake_chain = FakeBlockchain.new 10, block_size: 100_000
    end

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
