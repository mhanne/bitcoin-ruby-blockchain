class FakeChain

  include Bitcoin::Builder

  GENESIS = Bitcoin::P::Block.new("010000000000000000000000000000000000000000000000000000000000000000000000bbed8b03a246434da28c883e5c36860984cdbc9501e6751b6441dd5f0574aa3514b5d152f8ff071f533600000101000000010000000000000000000000000000000000000000000000000000000000000000ffffffff101ef6a77b8ec0a2aee3040628bef836c7ffffffff0100f2052a010000001976a91454bd602f3df3315c80a04326bd193a583a1d353988ac00000000".htb)

  attr_accessor :key, :store

  def initialize key, storage, command = nil
    @key, @store, @command = key, storage, command
    Bitcoin.network[:genesis_hash] = GENESIS.hash
    @store.new_block GENESIS
    @prev_hash = @store.get_head.hash
    @tx = []
  end

  def add_tx tx, conf = 0
    @tx << tx
    conf.times { new_block }
  end

  def new_block
    blk = build_block(Bitcoin.decode_compact_bits(Bitcoin.network[:proof_of_work_limit])) do |b|
      b.prev_block @prev_hash
      b.tx do |t|
        t.input {|i| i.coinbase }
        t.output do |o|
          o.value 5000000000
          o.script do |s|
            s.type :address
            s.recipient @key.addr
          end
        end
      end

      @tx.uniq(&:hash).each {|tx| b.tx tx }
      @tx = []
    end

    @prev_hash = blk.hash
    send_block(blk)
  end

  def send_block blk
    if @command
      EM.run do
        Bitcoin::Network::CommandClient.connect(*@command) do
          on_connected { request(:store_block, hex: blk.payload.hth) }
          on_response { EM.stop }
        end
      end
    end
    @store.new_block(blk)
  end   

end
