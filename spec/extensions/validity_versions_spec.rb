# frozen_string_literal: true
require_relative "spec_helper"

describe "validity_versions plugin" do
  before do
    @tzs = [Sequel.application_timezone, Sequel.database_timezone, Sequel.typecast_timezone]
    Sequel.default_timezone = :utc
    @db = Sequel.sqlite
    @db.create_table(:versions) do
      primary_key :id
      String :key, null: false
      Time :valid_from, null: false
      Time :valid_to
      String :value
      Integer :lock_version, null: false, default: 0
    end
    @c = Class.new(Sequel::Model(@db[:versions]))
    @c.plugin :validity_versions
    @t = lambda{|m, d| Time.utc(2026, m, d)}
    @key = 'sku-1'
    @c.create_version(@key, @t.call(1, 1), @t.call(4, 1), :value=>'a')
    @c.create_version(@key, @t.call(4, 1), @t.call(8, 1), :value=>'b')
    @c.create_version(@key, @t.call(8, 1), nil, :value=>'c')
  end

  after do
    Sequel.application_timezone, Sequel.database_timezone, Sequel.typecast_timezone = *@tzs
    @db.disconnect
  end

  def versions(key=@key)
    @c.versions_of(key).all
  end

  def interval(version)
    [version.valid_from&.utc, version.valid_to&.utc]
  end

  def value_at(time)
    (v = @c.as_of(@key, time)) && v.value
  end

  it "stores multiple versions for one logical key and queries them with as_of" do
    versions.map{|v| [interval(v), v.value]}.must_equal [
      [[@t.call(1, 1), @t.call(4, 1)], 'a'],
      [[@t.call(4, 1), @t.call(8, 1)], 'b'],
      [[@t.call(8, 1), nil], 'c']
    ]
    value_at(@t.call(1, 1)).must_equal 'a'
    value_at(@t.call(3, 31)).must_equal 'a'
    value_at(@t.call(4, 1)).must_equal 'b'
    value_at(@t.call(7, 31)).must_equal 'b'
    value_at(@t.call(8, 1)).must_equal 'c'
    value_at(Time.utc(2025, 12, 31)).must_be_nil
  end

  it "treats a nil valid_to as infinity" do
    value_at(Time.utc(2036, 1, 1)).must_equal 'c'
  end

  it "rejects empty, inverted, and nil-from intervals" do
    proc{@c.create_version('x', @t.call(2, 1), @t.call(2, 1))}.must_raise Sequel::Plugins::ValidityVersions::InvalidInterval
    proc{@c.create_version('x', @t.call(3, 1), @t.call(2, 1))}.must_raise Sequel::Plugins::ValidityVersions::InvalidInterval
    proc{@c.create_version('x', nil, @t.call(2, 1))}.must_raise Sequel::Plugins::ValidityVersions::InvalidInterval
    proc{@c.revise(@key, @t.call(3, 1), @t.call(2, 1), :value=>'z')}.must_raise Sequel::Plugins::ValidityVersions::InvalidInterval
    versions('x').must_equal []
  end

  it "rejects versions overlapping existing history, both via create_version and plain create" do
    proc{@c.create_version(@key, @t.call(3, 1), @t.call(5, 1))}.must_raise Sequel::Plugins::ValidityVersions::OverlappingVersions
    proc{@c.create_version(@key, Time.utc(2030, 1, 1), nil)}.must_raise Sequel::Plugins::ValidityVersions::OverlappingVersions
    proc{@c.create(:key=>@key, :valid_from=>@t.call(2, 1), :valid_to=>@t.call(3, 1))}.must_raise Sequel::Plugins::ValidityVersions::OverlappingVersions
    versions.length.must_equal 3
  end

  it "rejects revision attributes that include reserved columns" do
    proc{@c.revise(@key, @t.call(2, 1), @t.call(3, 1), :valid_from=>@t.call(2, 1))}.must_raise Sequel::Plugins::ValidityVersions::Error
    proc{@c.revise(@key, @t.call(2, 1), @t.call(3, 1), :key=>'other')}.must_raise Sequel::Plugins::ValidityVersions::Error
  end

  describe "after a revision spanning two boundaries" do
    before do
      @new = @c.revise(@key, @t.call(2, 1), @t.call(10, 1), :value=>'X')
    end

    it "splits covered versions and keeps old values on both sides" do
      versions.map{|v| [interval(v), v.value]}.must_equal [
        [[@t.call(1, 1), @t.call(2, 1)], 'a'],
        [[@t.call(2, 1), @t.call(10, 1)], 'X'],
        [[@t.call(10, 1), nil], 'c']
      ]
      interval(@new).must_equal [@t.call(2, 1), @t.call(10, 1)]
    end

    it "returns the correct version for as_of at every point" do
      value_at(@t.call(1, 1)).must_equal 'a'
      value_at(@t.call(1, 15)).must_equal 'a'
      value_at(@t.call(1, 31)).must_equal 'a'
      value_at(@t.call(2, 1)).must_equal 'X'
      value_at(@t.call(4, 1)).must_equal 'X'
      value_at(@t.call(8, 1)).must_equal 'X'
      value_at(@t.call(9, 30)).must_equal 'X'
      value_at(@t.call(10, 1)).must_equal 'c'
      value_at(Time.utc(2036, 1, 1)).must_equal 'c'
      value_at(Time.utc(2025, 12, 31)).must_be_nil
    end

    it "does not affect versions of other logical keys" do
      @c.create_version('other', @t.call(1, 1), nil, :value=>'o')
      @c.revise(@key, @t.call(3, 1), @t.call(4, 1), :value=>'Y')
      versions('other').map{|v| [interval(v), v.value]}.must_equal [[[@t.call(1, 1), nil], 'o']]
    end

    it "detects concurrent revisions and preserves all original intervals after the conflict" do
      before = versions.map{|v| [interval(v), v.value, v.lock_version]}
      plan = @c.plan_revision(@key, @t.call(1, 15), @t.call(3, 1), :value=>'Y')
      @c.revise(@key, @t.call(5, 1), @t.call(6, 1), :value=>'Z')
      proc{plan.commit}.must_raise Sequel::Plugins::ValidityVersions::Conflict
      versions.map{|v| [interval(v), v.value, v.lock_version]}.must_equal(
        @c.versions_of(@key).all.map{|v| [interval(v), v.value, v.lock_version]})
      expected = [
        [[@t.call(1, 1), @t.call(2, 1)], 'a'],
        [[@t.call(2, 1), @t.call(5, 1)], 'X'],
        [[@t.call(5, 1), @t.call(6, 1)], 'Z'],
        [[@t.call(6, 1), @t.call(10, 1)], 'X'],
        [[@t.call(10, 1), nil], 'c']
      ]
      versions.map{|v| [interval(v), v.value]}.must_equal expected
      value_at(@t.call(1, 20)).must_equal 'a'
      value_at(@t.call(2, 15)).must_equal 'X'
      value_at(@t.call(5, 15)).must_equal 'Z'
      value_at(@t.call(7, 1)).must_equal 'X'
      value_at(@t.call(11, 1)).must_equal 'c'
      # lock versions of rows untouched by the successful revision must be unchanged
      before.each do |int, val, lv|
        row = versions.find{|v| interval(v) == int && v.value == val}
        row.lock_version.must_equal lv if int == [@t.call(1, 1), @t.call(2, 1)] || int == [@t.call(10, 1), nil]
      end
    end

    it "rolls back the whole revision when a conflict occurs partway through" do
      plan = @c.plan_revision(@key, @t.call(1, 15), @t.call(9, 1), :value=>'Y')
      # concurrently delete the middle version so the plan's guarded update misses
      @c.versions_of(@key).where(:valid_from=>@t.call(2, 1)).delete
      proc{plan.commit}.must_raise Sequel::Plugins::ValidityVersions::Conflict
      versions.map{|v| [interval(v), v.value]}.must_equal [
        [[@t.call(1, 1), @t.call(2, 1)], 'a'],
        [[@t.call(10, 1), nil], 'c']
      ]
    end
  end

  describe "with merge_adjacent enabled" do
    before do
      @mc = Class.new(Sequel::Model(@db[:versions]))
      @mc.plugin :validity_versions, :merge_adjacent=>true
    end

    it "merges adjacent versions with identical content on create_version" do
      @mc.create_version('m', @t.call(1, 1), @t.call(2, 1), :value=>'a')
      @mc.create_version('m', @t.call(2, 1), @t.call(3, 1), :value=>'a')
      @mc.create_version('m', @t.call(3, 1), @t.call(4, 1), :value=>'b')
      @mc.versions_of('m').all.map{|v| [[v.valid_from.utc, v.valid_to&.utc], v.value]}.must_equal [
        [[@t.call(1, 1), @t.call(3, 1)], 'a'],
        [[@t.call(3, 1), @t.call(4, 1)], 'b']
      ]
    end

    it "merges the revised version with identical neighbors on both sides" do
      @mc.create_version('m', @t.call(1, 1), @t.call(4, 1), :value=>'a')
      @mc.revise('m', @t.call(2, 1), @t.call(3, 1), :value=>'a')
      @mc.versions_of('m').all.map{|v| [[v.valid_from.utc, v.valid_to&.utc], v.value]}.must_equal [
        [[@t.call(1, 1), @t.call(4, 1)], 'a']
      ]
    end

    it "keeps adjacent identical versions separate without the option" do
      @c.create_version('n', @t.call(1, 1), @t.call(2, 1), :value=>'a')
      @c.create_version('n', @t.call(2, 1), @t.call(3, 1), :value=>'a')
      @c.versions_of('n').count.must_equal 2
    end
  end
end
