# encoding: ascii-8bit

require_relative '../spec_helper'

include Bitcoin::Builder
include Bitcoin::Blockchain::Validation

describe "Blockchain import/export" do

  before do
    Bitcoin.network = :bitcoin
    @store = setup_db(:archive, :sqlite)
    FileUtils.mkdir_p "./spec/tmp"
  end

  after do
    close_db @store
    FileUtils.rm_rf "./spec/tmp"
  end

  it "should import and export data" do
    @store.height.should == -1

    import_file = "./spec/fixtures/reorg/blk_0_to_4.dat"
    export_file = "./spec/tmp/export.dat"
    @store.import(import_file,
                  resume_file: "/dev/null")

    @store.height.should == 4

    @store.export(export_file)

    File.binread(import_file).should ==
      File.binread(export_file)
  end

end
