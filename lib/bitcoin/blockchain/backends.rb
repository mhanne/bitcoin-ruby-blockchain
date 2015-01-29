module Bitcoin::Blockchain::Backends

  autoload :Base, 'bitcoin/blockchain/backends/base'
  autoload :SequelBase, 'bitcoin/blockchain/backends/sequel_base'


  require_relative "backends/dummy/dummy.rb"
  require_relative "backends/archive/archive.rb"
  require_relative "backends/utxo/utxo.rb"
#  BACKENDS = [:dummy, :sequel, :utxo]
#  BACKENDS.each {|b| autoload(b.to_s.capitalize, "bitcoin/blockchain/backends/#{b}/#{b}.rb") }

end
