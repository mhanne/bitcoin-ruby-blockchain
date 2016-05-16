module Bitcoin::Blockchain::Backends
  module ImportExport

    # import satoshi bitcoind blk0001.dat blockchain file
    def import filename, opts = {}
      opts[:resume_file] ||= File.join(ENV["HOME"], ".bitcoin-ruby", Bitcoin.network_name.to_s, "import_resume.state")
      if File.exist?(opts[:resume_file])
        @resume = File.read(opts[:resume_file]).split("|").map(&:to_i)
      else
        FileUtils.mkdir_p(File.dirname(opts[:resume_file]))
      end

      if File.file?(filename)
        log.info { "Importing #{filename}" }
        File.open(filename) do |file|
          @offset = @resume && @resume[1] ? @resume[1] : 0
          file.seek(@offset)

          until file.eof?
            magic = file.read(4)

            # bitcoind pads the ends of the block files so that it doesn't
            # have to reallocate space on every new block.
            break if magic == "\0\0\0\0"
            raise "invalid network magic" unless Bitcoin.network[:magic_head] == magic

            size = file.read(4).unpack("L")[0]

            # read 80 byte block header
            hdr_bytes = file.read(80)
            hdr = Bitcoin::P::Block.new
            hdr.parse_data_from_io(StringIO.new(hdr_bytes), true)

            # check if we already have a block with the same hash
            if has_block(hdr.hash)
              # if so, we skip reading the block data and seek to the next one
              print "\rAlready have block #{hdr.hash}"
              file.seek(file.pos + size - 80)
            else
              # if not, read the block data, parse it, and add it to the chain
              blk = Bitcoin::P::Block.new(hdr_bytes + file.read(size - 80))
              h, chain = new_block(blk)
              break  if opts[:max_height] && h >= opts[:max_height]
            end
            File.write(opts[:resume_file], [@import_file_num, @offset += (size + 8)].join("|"))
          end
        end
      elsif File.directory?(filename)
        Dir.entries(filename).sort.each do |file|
          next  unless file =~ /^blk(\d+)\.dat$/
          @import_file_num = $1.to_i
          next  if @resume && @resume[0] && @resume[0] > @import_file_num
          import(File.join(filename, file), opts)
          File.write(opts[:resume_file], [@import_file_num, 0].join("|"))
        end
      else
        raise "Import dir/file #{filename} not found"
      end
    end


    # export current blockchain to given file in blk*.dat format
    def export filename
      block = block_at_height(0)
      File.open(filename, "wb") do |file|
        write_block(file, block)
        while block = block.next_block
          write_block(file, block)
        end
      end
    end

    private

    # write a single block to the output file
    def write_block file, block
      payload = block.to_payload
      file.write Bitcoin.network[:magic_head]
      file.write [payload.bytesize].pack("L")
      file.write payload
    end

  end

end
