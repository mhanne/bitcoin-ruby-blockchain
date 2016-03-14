# encoding: ascii-8bit

require_relative '../spec_helper'
require 'json'

include Bitcoin

describe Bitcoin do

  before do
    Bitcoin.network = :bitcoin
    @key_data = {
      :priv => "2ebd3738f59ae4fd408d717bf325b4cb979a409b0153f6d3b4b91cdfe046fb1e",
      :pub => "035fcb2fb2802b024f371cc22bc392268cc579e47e7936e0d1f05064e6e1103b8a" }
    @key = Bitcoin::Key.new(@key_data[:priv], @key_data[:pub], false)
  end

  it "base58 encode decode" do
    iterate_fixtures_json(:base58_encode_decode) do |data|
      Bitcoin.encode_base58(data[0]).should == data[1]
      Bitcoin.decode_base58(data[1]).should == data[0]
    end
  end

  it "base58 keys valid" do
    iterate_fixtures_json(:base58_keys_valid) do |data|
      Bitcoin.network = data[2]["isTestnet"] ? :testnet3 : :bitcoin
      if data[2]["isPrivkey"]
        key = Bitcoin::Key.from_base58(data[0])
        key.priv.should == data[1]
        key.compressed.should == data[2]["isCompressed"]
      else
        Bitcoin.valid_address?(data[0]).should == true
        hash160, type = Bitcoin.decode_address(data[0])
        hash160.should == data[1]
        type.should == (data[2]["addrType"] == "script" ? :script_hash : :pubkey_hash)
      end
    end
    Bitcoin.network = :bitcoin
  end

  it "base58 keys invalid" do
    iterate_fixtures_json(:base58_keys_invalid) do |data|
      Bitcoin.valid_address?(data[0]).should == false
      Bitcoin.decode_address(data[0]).should == nil
      expect { 
        Bitcoin::Key.from_base58(data[0])
      }.to raise_error(Exception, /Invalid [version|checksum]/)
    end
  end

  it "sighash" do
    iterate_fixtures_json(:sighash) do |rawtx, script, index, hash_type, sighash|
      next  unless sighash
      tx = Bitcoin::P::Tx.new(rawtx.htb)
      raw_script = Script.new(script.htb).to_binary_without_signatures([])
      tx.signature_hash_for_input(index, raw_script, hash_type).reverse.hth.should == sighash
    end
  end

  it "canonical signatures" do
    run_signature_tests(:sig_canonical, true)
  end

  it "non-canonical signatures" do
    run_signature_tests(:sig_noncanonical, false)
  end

  it "script valid" do
    run_script_tests(:script_valid, true)
  end

  it "script invalid" do
    run_script_tests(:script_invalid, false)
  end

  it "tx valid" do
    run_tx_tests :tx_valid, true
  end

  it "tx invalid" do
    run_tx_tests :tx_invalid, false
  end


  def parse_script_str string
    return nil  unless string
    pushdata, length = nil, nil
    s = string.split(" ").map do |chunk|
      if chunk[0..2] == 'OP_'
        [Bitcoin::Script.const_get(chunk)].pack("C*")
      elsif chunk[0..1] == '0x'
        chunk[2..-1].htb
      elsif chunk[0] == "'" && chunk[-1] == "'"
        Bitcoin::Script.pack_pushdata chunk[1...-1]
      elsif Script.constants.include?("OP_#{chunk}".to_sym)
        [Bitcoin::Script.const_get("OP_#{chunk}")].pack("C*")
      else
        Script.pack_pushdata Script.new("").cast_to_string(chunk.to_i)
      end
    end
    s.compact.join
  end

  def iterate_fixtures_json name
    data = fixtures_file("bitcoind/#{name}.json").gsub(/^\s*#(.*?)$/, "")
    results = JSON.load(data).map.with_index do |data, i|
      print "#{i}\r"
      yield data
    end.compact
    print results.size.to_s.rjust(3)
  end

  def run_signature_tests(name, expected)
    iterate_fixtures_json(name) do |data|
      next  unless data =~ /^[a-fA-F0-9]+$/
      Script.check_signature_encoding?(data.htb, verify_dersig: true, verify_strictenc: true)
        .should == expected
    end
  end

  def run_script_tests(name, expected)
    iterate_fixtures_json(name) do |data|
      begin
        next  unless data.size >= 3
        script_sig_str, pk_script_str, flags, comment = *data

        script_sig = parse_script_str(script_sig_str)
        pk_script = parse_script_str(pk_script_str)

        flags = Hash[flags.split(",").map {|f| ["verify_#{f.downcase}".to_sym, true] }]

        prev_tx = build_tx do |t|
          t.input {|i| i.coinbase Script.from_string("0 0").raw }
          t.output {|o| o.txout.pk_script = pk_script }
        end

        tx = build_tx do |t|
          t.input {|i| i.prev_out prev_tx, 0 }
          t.output {|o| o.txout.pk_script = ""}
        end
        tx.in[0].script_sig = script_sig
        tx.instance_eval { @hash = hash_from_payload(to_payload) }

        silence_output do
          tx.verify_input_signature(0, prev_tx, Time.now.to_i, flags).should == expected
        end
      rescue
        # treat script errors as false result
        false.should == expected
      end
    end
  end

  def run_tx_tests(name, expected)
    iterate_fixtures_json(name) do |data|
      next (@desc ||= []) << data  if data.size <= 1
      desc = @desc.join("\n"); @desc = []; # puts desc

      prev_outs, tx_hex, flags_str = *data
      prev_outs_map = Hash[prev_outs.map {|h, i, s| [[h, i % 2**32], parse_script_str(s)] }]
      tx = Bitcoin::P::Tx.new(tx_hex.htb)
      flags = Hash[flags_str.split(",").map {|v| ["verify_#{v.downcase}".to_sym, true]}]

      result = tx.validator.validate(rules: [:syntax])
      tx.in.each.with_index do |txin, i|
        pk_script = prev_outs_map[[txin.prev_out_hash.reverse.hth, txin.prev_out_index]]
        result &&= tx.verify_input_signature(i, pk_script, Time.now.to_i, flags)
      end
      result.should == expected
    end
  end

  def silence_output
    stdout, $stdout = $stdout, StringIO.new
    yield
  ensure
    $stdout = stdout
  end

end

