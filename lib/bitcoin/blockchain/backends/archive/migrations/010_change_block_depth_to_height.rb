Sequel.migration do

  up do

    @log.info { "Running migration #{__FILE__}" }

    rename_column :blk, :depth, :height

  end

end
