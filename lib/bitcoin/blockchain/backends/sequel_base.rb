module Bitcoin::Blockchain::Backends

    class SequelBase < Base

      DEFAULT_CONFIG = {
        sqlite_pragmas: {
          # journal_mode pragma
          journal_mode: false,
          # synchronous pragma
          synchronous: false,
          # cache_size pragma
          # positive specifies number of cache pages to use,
          # negative specifies cache size in kilobytes.
          cache_size: -200_000,
        }
      }

      SEQUEL_ADAPTERS = { sqlite: "sqlite3", postgres: "pg", mysql: "mysql" }

      #set the connection
      def init_store_connection
        return  unless (self.is_a?(Archive) || self.is_a?(Utxo)) && @config[:db]
        @config[:db].sub!("~", ENV["HOME"])
        @config[:db].sub!("<network>", Bitcoin.network_name.to_s)
        adapter = SEQUEL_ADAPTERS[@config[:db].split(":").first] rescue nil
        Bitcoin.require_dependency(adapter, gem: adapter)  if adapter
        connect
      end

      # connect to database
      def connect
        Sequel.extension(:core_extensions, :sequel_3_dataset_methods)
        @db = Sequel.connect(@config[:db].sub("~", ENV["HOME"]))
        @db.extend_datasets(Sequel::Sequel3DatasetMethods)
        sqlite_pragmas; migrate; check_metadata
        log.info { "opened #{backend_name} store #{@db.uri}" }
      end

      # check if schema is up to date and migrate to current version if necessary
      def migrate
        migrations_path = File.join(File.dirname(__FILE__), "#{backend_name}/migrations")
        Sequel.extension :migration
        unless Sequel::Migrator.is_current?(@db, migrations_path)
          store = self; log = @log; @db.instance_eval { @log = log; @store = store }
          Sequel::Migrator.run(@db, migrations_path)
          unless (v = @db[:schema_info].first) && v[:magic] && v[:backend]
            @db[:schema_info].update(
              magic: Bitcoin.network[:magic_head].hth, backend: backend_name)
          end
        end
      end

      # check that database network magic and backend match the ones we are using
      def check_metadata
        version = @db[:schema_info].first
        unless version[:magic] == Bitcoin.network[:magic_head].hth
          name = Bitcoin::NETWORKS.find{|n,d| d[:magic_head].hth == version[:magic]}[0]
          raise "Error: DB #{@db.url} was created for '#{name}' network!"
        end
        unless version[:backend] == backend_name
          # rename "sequel" to "archive" when old db is opened
          if version[:backend] == "sequel" && backend_name == "archive"
            @db[:schema_info].update(backend: "archive")
          else
            raise "Error: DB #{@db.url} was created for '#{version[:backend]}' backend!"
          end
        end
      end

      # set pragma options for sqlite (if it is sqlite)
      def sqlite_pragmas
        return  unless (@db.is_a?(Sequel::SQLite::Database) rescue false)
        @config[:sqlite_pragmas].each do |name, value|
          @db.pragma_set name, value
          log.debug { "set sqlite pragma #{name} to #{value}" }
        end
      end

      # get the total on-disk size of this blockchain database.
      # Note: This won't work for in-memory or asynchronous/non-journaled sqlite dbs
      def database_size
        _, conf = @db.uri.split(":", 2)
        size = case @db.adapter_scheme
          when :sqlite
            File.size(@db.opts[:database])
          when :postgres
            @db.fetch("select pg_database_size('#{@db.opts[:database]}')").first[:pg_database_size]
          when :mysql
            @db.fetch("select sum(data_length+index_length) from information_schema.tables where table_schema = '#{@db.opts[:database]}';").first.to_a[0][1].to_i
          end
        size
      end

    end

end
