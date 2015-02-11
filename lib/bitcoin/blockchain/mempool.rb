# The Mempool stores unconfirmed transactions to be included in a block.
# All transactions are validated and checked for doublespends. If a doublespend
# is detected, the doublespending tx is stored separately, and the tx that is
# being doublespent is flagged.
# TODO:
#  check tx fee rules (optional)
#  check is standard rules (optional)
#  times_seen: count every peer only once
#  reorgs! (remove all transactions spending outputs that are in the old main block but not the new one)
#  compute propagation / confidence values based on last x seen
#  time-out rejected txs more often
#  make payload in callbacks optional
#  send / answer "mempool" messages
# NOTES
#  mempool archive node 96.2.103.25
class Bitcoin::Blockchain::Mempool

  # A MempoolTx represents a Bitcoin::P::Tx living in the mempool.
  # It has +created_at+ and +updated_at+ timestamps, a count of the number
  # of +times_seen+, and an +is_doublespent+ flag inidcating if this tx has
  # been doublespent by another one.
  class MempoolTx < Bitcoin::Protocol::Tx

    # Blockchain store used to fetch prev txs to compute priority
    attr_accessor :store

    # Mempool DB used to fetch depends / depending txs
    attr_accessor :db

    # Mempool ID of this tx
    attr_accessor :id

    # Timestamp when the tx was first seen
    attr_accessor :created_at

    # Timestamp when the tx was last seen
    attr_accessor :updated_at

    # How many times the tx was seen
    attr_accessor :times_seen

    # Total value of all inputs
    attr_accessor :input_value

    # Flag telling if this tx has been doublespent by another one
    attr_accessor :is_doublespent

    # IDs of the txs that have been doublespent by this one (if any)
    attr_accessor :doublespends

    def initialize store, db, tx_data
      @store, @db = store, db
      tx_data.each do |k, v|
        instance_variable_set "@#{k}", v
      end
      super(tx_data[:payload])
    end

    # Get the tx type (:accepted, :rejected, :doublespend)
    def type
      @type.is_a?(Fixnum) ? Bitcoin::Blockchain::Mempool::TYPES[@type] : @type.to_sym
    end

    # Calculate priority for this tx. Optionally accepts an array of +prev_txs+ that holds
    # the transactions referenced by our inputs.
    def priority prev_txs = nil
      @in.map.with_index do |txin, idx|
        prev_hash = txin.prev_out.reverse.hth

        next 0 unless prev_tx = prev_txs ? prev_txs[idx] : @store.get_tx(prev_hash)
        prev_tx.out[txin.prev_out_index].value * prev_tx.confirmations rescue 0
      end.inject(:+) / @payload.bytesize
    end

    # list of tx hashes this one depends on to be valid
    def depends
      @db[:mempool_depends].where(depending: id).map {|d|
        @db[:mempool_transactions][id: d[:depends]][:hash].hth }
    end

    # list of tx hashes that depend on this one to be valid
    def depending
      @db[:mempool_depends].where(depends: id).map {|d|
        @db[:mempool_transactions][id: d[:depending]][:hash].hth }
    end

    # A MempoolTx always has 0 confirmations.
    def confirmations; 0; end

    def accepted?; type == :accepted; end
    def rejected?; type == :rejected; end

    # has this tx been doublespent by any other in the mempool?
    def doublespent?; doublespend? || is_doublespent; end

    # has this tx been the one doublespending another previously valid tx?
    # (i.e. the doublespend occured when this tx hit our node)
    def doublespend?; type == :doublespend; end

  end

  # Blockchain backend used to validate new transactions
  attr_reader :store, :db, :opts

  TYPES = [:accepted, :rejected, :doublespend]

  def initialize store, opts = {}
    @store = store
    @opts = { max_age: 600, db: "sqlite:/", log_level: :warn }.merge(opts)
    @db = Sequel::Database.connect(@opts[:db])
    log.level = @opts[:log_level]
    migrate
    log.info { "Opened mempool DB #{@opts[:db]} with #{transactions.count} transactions." }
    @inv = {}
    @notifiers = {}
  end

  def subscribe channel
    @notifiers[channel.to_sym] ||= EM::Channel.new
    @notifiers[channel.to_sym].subscribe {|*data| yield(*data) }
  end

  def push_notification channel, message
    @notifiers[channel.to_sym].push(message)  if @notifiers[channel.to_sym]
  end

  def migrate
    binary = @db.database_type == :postgres ? :bytea : :blob

    # all the regular transactions living in the mempool
    unless @db.tables.include?(:mempool_transactions)
      @db.create_table(:mempool_transactions) do |t|
        t.primary_key :id
        t.integer :type, null: false, index: true
        t.column :hash, binary, unique: true, null: false, index: true
        t.column :payload, binary, null: false
        t.timestamp :created_at, null: false, index: true
        t.timestamp :updated_at, null: false, index: true
        t.integer :times_seen, null: false, default: 1, index: true
        t.column :doublespends, binary, index: true
        t.boolean :is_doublespent, null: false, default: false, index: true
        t.bigint :input_value, null: false, index: true
      end

    end

    # list of outputs spent by the transactions in the mempool
    unless @db.tables.include?(:mempool_spent_outs)
      @db.create_table(:mempool_spent_outs) do |t|
        t.primary_key :id
        t.column :prev_out, binary, unique: true, null: false # <hash>:<i>
        t.integer :spent_by, null: false, index: true # mempool_tx.id
      end
    end

    unless @db.tables.include?(:mempool_depends)
      @db.create_table(:mempool_depends) do |t|
        # tx id that is invalid without another tx being accepted first
        t.integer :depending, null: false, index: true

        # tx id that is required to make the +depending+ tx valid
        t.integer :depends, null: false, index: true
      end
    end
  end

  def log; @log ||= Bitcoin::Logger.create(:mempool); end
  def transactions; @db[:mempool_transactions]; end
  def spent_outs; @db[:mempool_spent_outs]; end

  [:accepted, :rejected, :doublespend].each do |type|
    define_method(type) { transactions.where(type: TYPES.index(type)) }
    define_method("#{type}?") {|hash|
      !!transactions[hash: hash.htb.blob, type: TYPES.index(:accepted)] }
  end


  # add +tx+ to the mempool. returns the mempool id or nil if the tx isn't valid
  # if the tx is a doublespend, it will be stored anyway, and the tx that is being
  # doublespent marked as such.
  def add tx
    start_time = Time.now
    if existing = transactions[hash: tx.hash.htb.blob]
      # if tx already exists, update times_seen and updated_at values
      transactions.where(id: existing[:id])
        .update(times_seen: existing[:times_seen] + 1, updated_at: Time.now)
    else
      # validate tx
      validator = tx.validator(@store)
      validator.mempool = self
      if validator.validate
        new_tx_id, priority = save_tx(tx, :accepted, validator.prev_txs)
        log.info { "Accepted #{tx.hash} in %.4fs (priority: #{priority})." % (Time.now - start_time) }
      else
        if validator.error[0] == :prev_out
          validator.error[1].each do |tx_hash, idx|
            next  unless spent = spent_outs[prev_out: "#{tx_hash.htb}:#{idx}".blob]
            log.info { "Tx #{tx.hash} is a double spend." }
            log.debug { validator.error[1].inspect }
            save_tx(tx, :doublespend, validator.prev_txs, transactions[id: spent[:spent_by]][:hash])
            log.info { "Detected doublespend #{tx.hash} in %.4fs." % (Time.now - start_time) }
            return false
          end
        end
        save_tx(tx, :rejected, validator.prev_txs)
        log.info { "Rejected #{tx.hash} in %.4fs." % (Time.now - start_time) }
        log.debug { validator.error.inspect }
        return validator.error
      end
    end
    new_tx_id || existing[:id]
  end

  def inv hash
    if existing = transactions[hash: hash.blob]
      times_seen = existing[:times_seen] + 1
      transactions.where(id: existing[:id]).update(times_seen: times_seen)
      push_notification(:seen, { id: existing[:id], hash: existing[:hash].hth, times_seen: times_seen, updated_at: existing[:updated_at] })
      #push_notification(:confirmed, { id: existing[:id], hash: existing[:hash].hth })
    else
      @inv[hash] ||= 0; @inv[hash] += 1
    end
  end

  # tell the mempool that given transactions +hashes+ have been confirmed into a block.
  # remove those transactions from the mempool, delete obsolete dependencies, and
  # permanently invalidate any doublespends of it.
  def confirmed_txs hashes
    txs = transactions.where(hash: hashes.map(&:htb).map(&:blob))
    return false unless txs.any?

    # reject all doublespends involving the newly confirmed transactions,
    [ transactions.where(doublespends: hashes.map(&:htb).map(&:blob)),
      transactions.where(hash: txs.map {|t| t[:doublespends]}.compact.map(&:blob))
    ].each {|ds| ds.update(type: TYPES.index(:rejected)) }

    # remove spent_outs records
    ids = txs.map {|t| t[:id] }
    spent_outs.where(spent_by: ids).delete
    @db[:mempool_depends].where("depending IN ? OR depends IN ?", ids, ids).delete

    # send notification about confirmed txs
    txs.all.each.with_index do |tx, i|
      push_notification(:confirmed, {
          id: tx[:id],
          hash: tx[:hash].hth,
          type: TYPES[tx[:type]] })
    end

    txs.delete # delete the actual transaction records

    log.info { "Confirmed #{hashes.count} transactions." }
    true
  end

  # clean up old transactions that haven't been seen for a while
  def cleanup
    txs = transactions.where("updated_at < ?", Time.now - opts[:max_age])
    spent_outs.where(spent_by: txs.map{|t| t[:id]}).delete
    txs.delete
  end

  # check if tx with given +hash+ exists in the mempool (not in doublespends)
  def exists? hash
    !!transactions[hash: hash.htb.blob]
  end

  # check if output specified by +prev_tx_hash+ and +prev_out_index+ has already been spent
  # by any mempool tx
  def spent? prev_tx_hash, prev_out_index
    !!spent_outs[prev_out: "#{prev_tx_hash.htb}:#{prev_out_index}".blob]
  end

  # get the tx for given +hash+
  def get hash, type = nil
    if type
      tx_data = transactions[hash: hash.htb.blob, type: TYPES.index(type.to_sym)]
    else
      tx_data = transactions[hash: hash.htb.blob]
    end
    return MempoolTx.new(store, db, tx_data)  if tx_data
  end

  def get_txs hashes, type = nil
    if type
      txs = transactions[hash: hashes.map(&:htb).map(&:blob), type: TYPES.index(type.to_sym)]
    else
      txs = transactions[hash: hashes.map(&:htb).map(&:blob)]
    end
    txs.map {|t| MempoolTx.new(store, db, t) }
  end
  
  protected

  def save_tx tx, type, prev_txs, doublespent_hash = nil
    times_seen = @inv.delete(tx.hash.htb) || 0

    input_value = tx.in.map.with_index {|i, idx|
      prev_txs[idx].out[i.prev_out_index].value rescue 0 }.inject(:+) || 0

    tx_data = { type: TYPES.index(type), hash: tx.hash.htb.blob,
      payload: tx.to_payload.blob, input_value: input_value,
      created_at: Time.now, updated_at: Time.now, times_seen: times_seen }

    tx_data[:doublespends] = doublespent_hash  if type == :doublespend

    # store tx
    new_tx_id = transactions.insert(tx_data)

    case type
    when :accepted
      # store spent prev outs
      tx.in.each do |txin|
        prev_out = "#{txin.prev_out.reverse}:#{txin.prev_out_index}"
        spent_outs.insert(prev_out: prev_out.blob, spent_by: new_tx_id)
      end

      # insert "depends" records to mark mempool txs this one depends on
      prev_txs.each do |tx|
        next  unless tx.class == MempoolTx
        @db[:mempool_depends].insert(depending: new_tx_id,
          depends: transactions[hash: tx.hash.htb.blob][:id])
      end
    when :rejected
      # TODO
    when :doublespend
      transactions.where(hash: doublespent_hash).update(is_doublespent: true)
    end

    mempool_tx = MempoolTx.new(store, db, tx_data)
    priority = mempool_tx.priority(prev_txs)

    push_notification(type, { id: new_tx_id, type: type, hash: tx.hash,
        payload: tx.to_payload.hth, priority: priority, times_seen: times_seen,
        created_at: tx_data[:created_at], updated_at: tx_data[:updated_at] })

    return new_tx_id, priority
  end

end
