# encoding: ascii-8bit

require_relative '../spec_helper'
require_relative '../helpers/fake_chain.rb'

include Bitcoin::Builder
RULES = Bitcoin::Blockchain::Validation::Block::RULES

[
  :sqlite,
  :postgres
 ].each do |adapter|

  next  unless adapter == :sqlite || ENV["TEST_DB_#{adapter.upcase}"]

  describe "Bitcoin::Blockchain::Mempool (#{adapter})" do

    before(:all) do
      Bitcoin.network = :regtest
      @key = Bitcoin::Key.from_base58("92Pt1VX7sBoW37svE1X3mHUGjkYMbfj1D7fy2nTh8fezot3KdLp")
      @rule_idx = RULES[:context].index(:min_timestamp)
      RULES[:context].delete(:min_timestamp)
      @store = setup_db :archive, adapter, index_nhash: true, log_level: :error, mempool: {log_level: :error}
      @fake_chain = FakeChain.new(@key, @store)
      @fake_chain.new_block
      n = 2
      if @store.get_depth < n
        puts "Creating fake chain..."
        n.times { print "\rGenerated block #{@fake_chain.new_block[0]}/#{n}"; sleep 0.2 }
      end
      @store.get_depth.should >= n
    end

    after(:all) do
      RULES[:context].insert(@rule_idx, :min_timestamp)
      Bitcoin.network = :testnet
    end

    before do
      db = adapter == :sqlite ? "sqlite:/" : ENV["TEST_DB_#{adapter.upcase}"]
      @mempool = mp = Bitcoin::Blockchain::Mempool.new(@store, log_level: :warn, db: db)
      @store.instance_eval { @mempool = mp }
      @mempool = @store.mempool

      if adapter == :postgres
        @mempool.instance_eval do
          [:transactions, :spent_outs, :depends].each do |table|
            @db["mempool_#{table}".to_sym].delete
            @db["ALTER SEQUENCE mempool_#{table}_id_seq RESTART WITH 1;"].all rescue nil
          end
        end
      end

      # a valid transaction
      @valid_tx = build_tx do |t|
        t.input {|i| i.prev_out @store.get_head.tx[0], 0; i.signature_key @key }
        t.output {|o| o.value 50e8; o.to @key.addr }
      end

      # tx doublespending the first valid one
      @doublespend_tx = build_tx do |t|
        t.input {|i| i.prev_out @store.get_head.tx[0], 0; i.signature_key @key }
        t.output {|o| o.value 50e8; o.to Bitcoin::Key.generate.addr }
      end

      # invalid tx, also doublespending, but doesn't even have a valid signature
      @invalid_tx = build_tx do |t|
        t.input {|i| i.prev_out @store.get_head.tx[0], 0 } # no signature key
        t.output {|o| o.value 50e8; o.to Bitcoin::Key.generate.addr }
      end

      # a tx spending the first one to form a chain of unconfirmed txs
      @chain_tx = build_tx do |t|
        t.input {|i| i.prev_out @valid_tx, 0; i.signature_key @key }
        t.output {|o| o.value 50e8; o.to Bitcoin::Key.generate.addr }
      end
    end

    it "should add valid tx to mempool" do
      @mempool.add(@valid_tx).should == 1
      @mempool.get(@valid_tx.hash).hash.should == @valid_tx.hash
    end

    it "should update times_seen value" do
      3.times { @mempool.add(@valid_tx).should == 1 }
      @mempool.get(@valid_tx.hash).times_seen.should == 2

      @mempool.inv(@valid_tx.hash.htb)
      @mempool.get(@valid_tx.hash).times_seen.should == 3
    end

    it "should cache invs until the full tx is received" do
      3.times { @mempool.inv(@valid_tx.hash.htb) }
      @mempool.add(@valid_tx).should == 1
      @mempool.get(@valid_tx.hash).times_seen.should == 3
      3.times { @mempool.inv(@valid_tx.hash.htb) }
      @mempool.get(@valid_tx.hash).times_seen.should == 6
    end

    it "should add chain of valid tx to mempool" do
      @mempool.add(@valid_tx).should == 1
      @mempool.add(@chain_tx).should == 2
    end

    it "should not add invalid tx to mempool" do
      @mempool.add(@invalid_tx).should == [:signatures, [0]]
    end

    it "should remove confirmed tx from mempool" do
      @fake_chain.add_tx(@valid_tx, 1)
      @mempool.get(@valid_tx.hash).should == nil
    end

    it "should remove confirmed tx from mempool" do
      @mempool.add(@valid_tx).should == 1
      @mempool.confirmed_txs([@valid_tx.hash]).should == true
      @mempool.confirmed_txs([@valid_tx.hash]).should == false # already removed
      @mempool.get(@valid_tx.hash).should == nil
    end

    it "should clear old transactions from the mempool" do
      @mempool = Bitcoin::Blockchain::Mempool.new(@store, max_age: 0.1)
      @mempool.add(@valid_tx).should == 1
      sleep 0.1
      @mempool.add(@chain_tx).should == 2
    
      @mempool.cleanup

      @mempool.get(@valid_tx.hash).should == nil
      @mempool.get(@chain_tx.hash).hash.should == @chain_tx.hash
    end

    # TODO it should clear transactions from mempool once they are included in a block

    describe :doublespend do

      before do
        # double-spend an already confirmed tx
        @mempool.add(@valid_tx).should == 1
        @mempool.add(@doublespend_tx).should == false
      end

      it "should add doublespend tx to mempool" do
        tx = @mempool.get(@valid_tx.hash)
        tx.hash.should == @valid_tx.hash
        tx.doublespent?.should == true
        tx.doublespend?.should == false

        ds_tx = @mempool.get(@doublespend_tx.hash)
        ds_tx.hash.should == @doublespend_tx.hash
        ds_tx.doublespent?.should == true
        ds_tx.doublespend?.should == true

        @mempool.doublespend.count.should == 1
        @mempool.doublespend.first[:hash].hth.should == @doublespend_tx.hash
      end

      it "should get doublespend tx by hash" do
        @mempool.get(@doublespend_tx.hash).hash.should == @doublespend_tx.hash
      end

      it "should confirm doublespend tx - then the other one should become rejected" do
        @fake_chain.add_tx(@doublespend_tx, 1)
        @mempool.get(@valid_tx.hash).type.should == :rejected
      end

      it "should confirm doublespent tx" do
        @fake_chain.add_tx(@valid_tx, 1)
        @mempool.get(@doublespend_tx.hash).type.should == :rejected
      end

      # it "should remove doublespend tx" do
      #   @mempool.remove(@doublespend_tx.hash).should == true
      #   @mempool.get(@doublespend_tx.hash).should == nil
      # end

      # it "should list doublespends" do
      #   @mempool.list_doublespends.should == [@doublespend_tx]
      #   @mempool.list_doublespends.first.is_doublespent.should == true
      # end

      it "should consider transactions spending doublespent transactions as invalid" do
        @mempool.add(@chain_tx).should == [:prev_out, [[@valid_tx.hash, 0]]]
      end

      # it "should send doublespend alert"

      it "should treat mutant txs (different hash, same nhash) as doublespends" do
        mutant_tx = @valid_tx.dup.instance_eval do
          @in[0].script_sig = "a" + @in[0].script_sig
          @payload = to_payload
          @hash = hash_from_payload(@payload)
          self
        end
        @mempool.add(@valid_tx).should == 1

        mutant_tx.instance_eval { @validator = nil }
        @mempool.add(mutant_tx).should == false
        @mempool.get(@valid_tx.hash).doublespent?.should == true


        @mempool.get(mutant_tx.hash).doublespent?.should == true
      end

    end

    describe :priority do

      before do
        @mempool.add(@valid_tx)
      end

      it "should get priority for tx" do
        # input value * input age / tx size
        @mempool.get(@valid_tx.hash).priority.should == (50e8 * 1 / @valid_tx.payload.bytesize).to_i
      end

      it "should increase priority as the prev tx gets confirmations" do
        @mempool.get(@valid_tx.hash).priority.should == (50e8 * 1 / @valid_tx.payload.bytesize).to_i
        @fake_chain.new_block
        @mempool.get(@valid_tx.hash).priority.should == (50e8 * 2 / @valid_tx.payload.bytesize).to_i
        @fake_chain.new_block
        @mempool.get(@valid_tx.hash).priority.should == (50e8 * 3 / @valid_tx.payload.bytesize).to_i
      end

      it "should have 0 priority for chained transactions" do
        @mempool.add(@chain_tx)
        @mempool.get(@chain_tx.hash).priority.should == 0
      end

    end

    describe :depends do

      before do
        @mempool.add(@valid_tx)
        @mempool.add(@chain_tx)
      end

      it "should list dependent tx hashes" do
        @mempool.get(@chain_tx.hash).depends.should == [@valid_tx.hash]
      end

      it "should list depending tx hashes" do
        @mempool.get(@valid_tx.hash).depending.should == [@chain_tx.hash]
      end

      it "should remove dependent tx links" do
        @mempool.confirmed_txs([@valid_tx.hash])
        @mempool.get(@chain_tx.hash).depends.should == []
      end

      it "should remove depending tx links" do
        @mempool.confirmed_txs([@chain_tx.hash])
        @mempool.get(@valid_tx.hash).depending.should == []
      end

    end

  end

end
