# encoding: ascii-8bit

require_relative '../spec_helper'

include Bitcoin
include Bitcoin::Blockchain

[
  [:dummy],
  [:archive, :sqlite],
  # [:utxo, :sqlite, index_all_addrs: true],
  [:archive, :postgres],
  # [:utxo, :postgres, index_all_addrs: true],
  [:archive, :mysql],
  # [:utxo, :mysql, index_all_addrs: true],
].compact.each do |options|

  describe "Blockchain::Models (#{options[0].to_s.capitalize}Store, #{options[1]})" do

    before do
      Bitcoin::network = :testnet
      Bitcoin.network[:no_difficulty] = true
      Bitcoin.network[:proof_of_work_limit] = Bitcoin.encode_compact_bits("ff"*32)

      skip  unless @store = setup_db(*options)
      def @store.in_sync?; true; end

      @store.store_block(P::Block.new(fixtures_file('testnet/block_0.bin')))
      @store.store_block(P::Block.new(fixtures_file('testnet/block_1.bin')))
      @store.store_block(P::Block.new(fixtures_file('testnet/block_2.bin')))
      @store.store_block(P::Block.new(fixtures_file('testnet/block_3.bin')))

      unless @store.backend_name == "utxo"
        @store.store_tx(P::Tx.new(fixtures_file('rawtx-01.bin')), false)
        @store.store_tx(P::Tx.new(fixtures_file('rawtx-02.bin')), false)
      end
    end

    after do
      Bitcoin.network.delete :no_difficulty
      close_db @store
    end

    describe "Block" do

      let(:block) { @store.block_at_height(1) }

      it "should get prev block" do
        block.prev_block.should == @store.block_at_height(0)
      end

      it "should get next block" do
        block.next_block.should == @store.block_at_height(2)
      end

      it "should get total out" do
        block.total_out.should == 5000000000
      end

      it "should get total in" do
        block.total_in.should == 5000000000
      end

      it "should get total fee" do
        block.total_fee.should == 0
      end

      it "should amend #to_hash/#to_json with next_in" do
        hash = @store.block_at_height(2).to_hash(with_next_block: true)
        hash["next_block"].should == @store.block_at_height(3).hash
        hash = @store.block_at_height(3).to_hash(with_next_block: true)
        hash["next_block"].should == nil
      end

    end

    describe "Tx" do

      let(:tx) { @store.block_at_height(1).tx[0] }

      it "should get block" do
        tx.block.should == @store.block_at_height(1)
      end

      it "should get confirmations" do
        tx.confirmations.should == 3
      end

      it "should get total out" do
        tx.total_out.should == 5000000000
      end

      it "should get total in" do
        tx.total_in.should == 5000000000
      end

      it "should get fee" do
        tx.fee.should == 0
      end

      it "should amend #to_hash/#to_json with next_in" do
        @key = Key.generate
        block_4 = create_block @store.head.hash, true, [], @key
        block_5 = create_block block_4.hash, true, [->(t) {
          create_tx(t, block_4.tx.first, 0, [[50, @key]]) }], @key

        tx = @store.block_at_height(4).tx.first
        tx.to_hash(with_next_in: true)["out"].first.should == { "value" => "50.00000000",
          "scriptPubKey" => "OP_DUP OP_HASH160 #{@key.hash160} OP_EQUALVERIFY OP_CHECKSIG",
          "next_in" => { "hash" => block_5.tx.last.hash, "n" => 0 } }
      end

    end

  end

end
