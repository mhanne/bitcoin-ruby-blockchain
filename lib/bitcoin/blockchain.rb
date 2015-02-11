# encoding: ascii-8bit
require 'bundler'
Bundler.setup
require 'bitcoin'
require_relative "blockchain/version"

# The storage implementation supports different backends, which inherit from
# Storage::StoreBase and implement the same interface.
# Each backend returns Storage::Models objects to easily access helper methods and metadata.
#
# The most stable backend is Backends::SequelStore, which uses sequel and can use all
# kinds of SQL database backends.
module Bitcoin::Blockchain

  # can't be autoloaded because it adds methods to Block/Tx that are usually used to access it
  require "bitcoin/blockchain/validation"

  autoload :Backends, "bitcoin/blockchain/backends"
  autoload :Models, "bitcoin/blockchain/models"
  autoload :Mempool, "bitcoin/blockchain/mempool"

  @log = Bitcoin::Logger.create(:storage)
  def self.log; @log; end

  def self.create_store(backend, config)
    if backend.to_sym == :sequel
      backend = :archive
      log.warn { "The 'sequel' backend has been renamed to 'archive', please adjust your config." }
    end
    Backends.const_get(backend.capitalize).new(config)
  end

end

# TODO: someday sequel will support #blob directly and #to_sequel_blob will be gone
class String; def blob; ::Sequel::SQL::Blob.new(self); end; end
