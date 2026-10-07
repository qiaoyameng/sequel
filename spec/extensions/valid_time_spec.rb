# frozen_string_literal: true
require_relative "spec_helper"

begin
  require 'sqlite3'
rescue LoadError
  # sqlite3 not available, skip valid_time plugin specs
else

describe "valid_time plugin" do
  before do
    @old_application_timezone = Sequel.application_timezone
    @old_database_timezone = Sequel.database_timezone
    Sequel.application_timezone = :utc
    Sequel.database_timezone = :utc
    @db = Sequel.sqlite
    @db.create_table(:products) do
      primary_key :id
      String :sku, :null=>false
      Time :valid_from, :null=>false
      Time :valid_to
      Integer :lock_version, :null=>false, :default=>0
      String :name
      Integer :price
    end
    @c = Class.new(Sequel::Model(@db[:products]))
    @c.plugin :valid_time, :key=>:sku
    @t0 = Time.utc(2026, 1, 1)
    @t1 = Time.utc(2026, 2, 1)
    @t2 = Time.utc(2026, 3, 1)
  end

  after do
    @db.disconnect
    Sequel.application_timezone = @old_application_timezone
    Sequel.database_timezone = @old_database_timezone
  end

  def versions(key='A')
    @c.history(key).all
  end

  def create_three_versions
    @c.create_version('A', @t0, @t1, :name=>'v1', :price=>10)
    @c.create_version('A', @t1, @t2, :name=>'v2', :price=>20)
    @c.create_version('A', @t2, nil, :name=>'v3', :price=>30)
  end

  it "stores multiple versions per logical key and returns the version valid at a given time via as_of" do
    create_three_versions
    @c.as_of('A', @t0 - 1).must_be_nil
    @c.as_of('A', @t0).name.must_equal 'v1'
    @c.as_of('A', @t1 - 1).name.must_equal 'v1'
    @c.as_of('A', @t1).name.must_equal 'v2'
    @c.as_of('A', @t2 - 1).name.must_equal 'v2'
    @c.as_of('A', @t2).name.must_equal 'v3'
    @c.as_of('A', Time.utc(2030, 1, 1)).name.must_equal 'v3'
    @c.as_of('B', @t1).must_be_nil
  end

  it "uses nil valid_to as infinity" do
    create_three_versions
    v = versions.last
    v.valid_to.must_be_nil
    @c.as_of('A', Time.utc(9999, 12, 31)).id.must_equal v.id
  end

  it "rejects empty, inverted, and unbounded-start intervals" do
    proc{@c.create_version('A', @t0, @t0)}.must_raise(Sequel::Plugins::ValidTime::InvalidInterval)
    proc{@c.create_version('A', @t1, @t0)}.must_raise(Sequel::Plugins::ValidTime::InvalidInterval)
    proc{@c.create_version('A', nil, @t0)}.must_raise(Sequel::Plugins::ValidTime::InvalidInterval)
    proc{@c.revise('A', @t0, @t0, :name=>'x')}.must_raise(Sequel::Plugins::ValidTime::InvalidInterval)
    proc{@c.revise('A', @t1, @t0, :name=>'x')}.must_raise(Sequel::Plugins::ValidTime::InvalidInterval)
    versions.must_be_empty
  end

  it "rejects inserting a version overlapping existing history" do
    create_three_versions
    proc{@c.create_version('A', @t0, @t1)}.must_raise(Sequel::Plugins::ValidTime::OverlappingHistory)
    proc{@c.create_version('A', @t0 + 86400, @t0 + 2*86400)}.must_raise(Sequel::Plugins::ValidTime::OverlappingHistory)
    proc{@c.create_version('A', Time.utc(2025, 1, 1), nil)}.must_raise(Sequel::Plugins::ValidTime::OverlappingHistory)
    versions.length.must_equal 3
  end

  it "allows inserting versions adjacent to existing history" do
    create_three_versions
    @c.create_version('A', Time.utc(2025, 12, 1), @t0, :name=>'v0', :price=>5)
    versions.map{|v| v.name}.must_equal %w[v0 v1 v2 v3]
  end

  it "splits covered intervals across two boundaries and preserves old values on both sides" do
    create_three_versions
    from = Time.utc(2026, 1, 15)
    to = Time.utc(2026, 3, 15)
    @c.revise('A', from, to, :name=>'new', :price=>99)

    vs = versions
    vs.length.must_equal 3
    vs[0].name.must_equal 'v1'
    vs[0].valid_from.must_equal @t0
    vs[0].valid_to.must_equal from
    vs[1].name.must_equal 'new'
    vs[1].price.must_equal 99
    vs[1].valid_from.must_equal from
    vs[1].valid_to.must_equal to
    vs[2].name.must_equal 'v3'
    vs[2].price.must_equal 30
    vs[2].valid_from.must_equal to
    vs[2].valid_to.must_be_nil

    # point-by-point as_of checks across both boundaries
    @c.as_of('A', @t0).name.must_equal 'v1'
    @c.as_of('A', from - 1).name.must_equal 'v1'
    @c.as_of('A', from).name.must_equal 'new'
    @c.as_of('A', @t1).name.must_equal 'new'
    @c.as_of('A', @t2).name.must_equal 'new'
    @c.as_of('A', to - 1).name.must_equal 'new'
    @c.as_of('A', to).name.must_equal 'v3'
    @c.as_of('A', Time.utc(2030, 1, 1)).name.must_equal 'v3'
  end

  it "revises a range extending to infinity when to is nil" do
    create_three_versions
    from = Time.utc(2026, 1, 15)
    @c.revise('A', from, nil, :name=>'new', :price=>99)
    vs = versions
    vs.length.must_equal 2
    vs[0].name.must_equal 'v1'
    vs[0].valid_to.must_equal from
    vs[1].name.must_equal 'new'
    vs[1].valid_from.must_equal from
    vs[1].valid_to.must_be_nil
    @c.as_of('A', Time.utc(2030, 1, 1)).name.must_equal 'new'
  end

  it "rolls back the whole revision on failure, preserving all original intervals" do
    create_three_versions
    before = versions.map{|v| [v.valid_from, v.valid_to, v.name, v.price, v.lock_version]}
    proc{@c.revise('A', Time.utc(2026, 1, 15), Time.utc(2026, 3, 15), :name=>'new', :no_such_column=>1)}.
      must_raise(Sequel::Error)
    after = versions.map{|v| [v.valid_from, v.valid_to, v.name, v.price, v.lock_version]}
    after.must_equal before
    @c.as_of('A', @t1).name.must_equal 'v2'
  end

  it "detects concurrent modification and raises a conflict instead of silently overwriting" do
    create_three_versions
    # two sessions read the same current versions of the logical key
    base = @c.history('A').all
    # a concurrent transaction modifies the same logical key
    @db[:products].where(:sku=>'A', :name=>'v2').
      update(:lock_version=>1, :price=>25)

    # the revision based on the stale snapshot must not silently overwrite
    proc{@c.revise('A', Time.utc(2026, 1, 15), Time.utc(2026, 3, 15), {:name=>'new', :price=>99}, :base=>base)}.
      must_raise(Sequel::Plugins::ValidTime::ConflictError)

    # the failed revision must leave the old records' traceability
    # information (intervals, content, lock versions) fully intact
    vs = versions
    vs.length.must_equal 3
    vs[0].valid_from.must_equal @t0
    vs[0].valid_to.must_equal @t1
    vs[0].name.must_equal 'v1'
    vs[1].valid_from.must_equal @t1
    vs[1].valid_to.must_equal @t2
    vs[1].name.must_equal 'v2'
    vs[1].price.must_equal 25
    vs[1].lock_version.must_equal 1
    vs[2].valid_from.must_equal @t2
    vs[2].valid_to.must_be_nil
    vs[2].name.must_equal 'v3'
    @c.as_of('A', @t1).name.must_equal 'v2'
  end

  it "keeps adjacent identical versions separate by default" do
    create_three_versions
    @c.revise('A', @t1, @t2, :name=>'v1', :price=>10)
    vs = versions
    vs.length.must_equal 3
    vs[0].name.must_equal 'v1'
    vs[1].name.must_equal 'v1'
    vs[0].valid_to.must_equal @t1
    vs[1].valid_from.must_equal @t1
  end

  it "merges adjacent identical versions when merge_adjacent is true" do
    @c.plugin :valid_time, :key=>:sku, :merge_adjacent=>true
    create_three_versions
    @c.revise('A', @t1, @t2, :name=>'v1', :price=>10)
    vs = versions
    vs.length.must_equal 2
    vs[0].name.must_equal 'v1'
    vs[0].valid_from.must_equal @t0
    vs[0].valid_to.must_equal @t2
    vs[1].name.must_equal 'v3'
    @c.as_of('A', @t1).name.must_equal 'v1'
  end

  it "supports custom column names" do
    @db.create_table(:rates) do
      primary_key :id
      String :code, :null=>false
      Time :starts_at, :null=>false
      Time :ends_at
      Integer :version, :null=>false, :default=>0
      Integer :rate
    end
    c = Class.new(Sequel::Model(@db[:rates]))
    c.plugin :valid_time, :key=>:code, :valid_from=>:starts_at, :valid_to=>:ends_at, :lock_column=>:version
    c.create_version('X', @t0, nil, :rate=>7)
    c.as_of('X', @t0).rate.must_equal 7
    c.revise('X', @t1, nil, :rate=>8)
    c.as_of('X', @t0).rate.must_equal 7
    c.as_of('X', @t1).rate.must_equal 8
  end
end
end
