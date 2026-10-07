# frozen_string_literal: true
require_relative "spec_helper"

Sequel.extension :heterogeneous_insert

describe "heterogeneous_insert extension" do
  before do
    @db = Sequel.mock.extension(:heterogeneous_insert)
    @ds = @db[:items]
  end

  it "should return nil without a query if given an empty array" do
    @ds.heterogeneous_insert([]).must_be_nil
    @db.sqls.must_equal []
  end

  it "should issue separate inserts inside a transaction by default" do
    @ds.heterogeneous_insert([{:x=>1}, {:x=>2}])
    @db.sqls.must_equal ['BEGIN',
      "INSERT INTO items (x) VALUES (1)",
      "INSERT INTO items (x) VALUES (2)",
      'COMMIT']
  end

  it "should have heterogeneous_import as an alias" do
    @ds.heterogeneous_import([{:x=>1}])
    @db.sqls.must_equal ['BEGIN', "INSERT INTO items (x) VALUES (1)", 'COMMIT']
  end

  it "should only combine adjacent rows with the same column set" do
    @ds = @ds.with_extend{def multi_insert_sql_strategy; :values end}
    @ds.heterogeneous_insert([{:a=>1}, {:a=>2, :b=>3}, {:b=>4}, {:a=>5}])
    @db.sqls.must_equal ['BEGIN',
      "INSERT INTO items (a) VALUES (1)",
      "INSERT INTO items (a, b) VALUES (2, 3)",
      "INSERT INTO items (b) VALUES (4)",
      "INSERT INTO items (a) VALUES (5)",
      'COMMIT']
  end

  it "should combine adjacent rows with the same column set across batches" do
    @ds = @ds.with_extend{def multi_insert_sql_strategy; :values end}
    @ds.heterogeneous_insert([{:a=>1}, {:a=>2}, {:b=>3}, {:a=>4}, {:a=>5}])
    @db.sqls.must_equal ['BEGIN',
      "INSERT INTO items (a) VALUES (1), (2)",
      "INSERT INTO items (b) VALUES (3)",
      "INSERT INTO items (a) VALUES (4), (5)",
      'COMMIT']
  end

  it "should not reorder rows into global column groups" do
    @ds = @ds.with_extend{def multi_insert_sql_strategy; :values end}
    @ds.heterogeneous_insert([{:a=>1}, {:b=>2}, {:a=>3}])
    @db.sqls.must_equal ['BEGIN',
      "INSERT INTO items (a) VALUES (1)",
      "INSERT INTO items (b) VALUES (2)",
      "INSERT INTO items (a) VALUES (3)",
      'COMMIT']
  end

  it "should treat rows with the same keys in a different order as the same column set" do
    @ds = @ds.with_extend{def multi_insert_sql_strategy; :values end}
    @ds.heterogeneous_insert([{:a=>1, :b=>2}, {:b=>3, :a=>4}])
    @db.sqls.must_equal ['BEGIN',
      "INSERT INTO items (a, b) VALUES (1, 2), (4, 3)",
      'COMMIT']
  end

  it "should keep missing columns out of the insert while still inserting explicit nil" do
    @ds.heterogeneous_insert([{:a=>1}, {:a=>nil, :b=>2}, {:b=>3}])
    @db.sqls.must_equal ['BEGIN',
      "INSERT INTO items (a) VALUES (1)",
      "INSERT INTO items (a, b) VALUES (NULL, 2)",
      "INSERT INTO items (b) VALUES (3)",
      'COMMIT']
  end

  it "should insert empty hashes using DEFAULT VALUES" do
    @ds.heterogeneous_insert([{}, {}])
    @db.sqls.must_equal ['BEGIN',
      "INSERT INTO items DEFAULT VALUES",
      "INSERT INTO items DEFAULT VALUES",
      'COMMIT']
  end

  it "should treat an empty hash as its own column set" do
    @ds = @ds.with_extend{def multi_insert_sql_strategy; :values end}
    @ds.heterogeneous_insert([{:a=>1}, {}, {:a=>2}])
    @db.sqls.must_equal ['BEGIN',
      "INSERT INTO items (a) VALUES (1)",
      "INSERT INTO items DEFAULT VALUES",
      "INSERT INTO items (a) VALUES (2)",
      'COMMIT']
  end

  it "should respect :slice and :commit_every for batch row limits" do
    @ds = @ds.with_extend{def multi_insert_sql_strategy; :values end}
    @ds.heterogeneous_insert([{:a=>1}, {:a=>2}, {:a=>3}, {:a=>4}], :slice=>2)
    @db.sqls.must_equal ['BEGIN',
      "INSERT INTO items (a) VALUES (1), (2)",
      "INSERT INTO items (a) VALUES (3), (4)",
      'COMMIT']

    @ds.heterogeneous_insert([{:a=>5}, {:a=>6}], :commit_every=>1)
    @db.sqls.must_equal ['BEGIN',
      "INSERT INTO items (a) VALUES (5)",
      "INSERT INTO items (a) VALUES (6)",
      'COMMIT']
  end

  it "should respect :max_parameters when choosing the batch size" do
    @ds = @ds.with_extend{def multi_insert_sql_strategy; :values end}
    @ds.heterogeneous_insert([{:a=>1}, {:a=>2}, {:a=>3}, {:a=>4}], :max_parameters=>2)
    @db.sqls.must_equal ['BEGIN',
      "INSERT INTO items (a) VALUES (1), (2)",
      "INSERT INTO items (a) VALUES (3), (4)",
      'COMMIT']
  end

  it "should use the smallest allowed slice from both row and parameter limits" do
    @ds = @ds.with_extend{def multi_insert_sql_strategy; :values end}
    @ds.heterogeneous_insert([{:a=>1}, {:a=>2}, {:a=>3}, {:a=>4}, {:a=>5}, {:a=>6}],
      :slice=>2, :max_parameters=>3)
    @db.sqls.must_equal ['BEGIN',
      "INSERT INTO items (a) VALUES (1), (2)",
      "INSERT INTO items (a) VALUES (3), (4)",
      "INSERT INTO items (a) VALUES (5), (6)",
      'COMMIT']
  end

  it "should slice according to the number of columns" do
    @ds = @ds.with_extend{def multi_insert_sql_strategy; :values end}
    @ds.heterogeneous_insert([{:a=>1, :b=>1}, {:a=>2, :b=>2}, {:a=>3, :b=>3}],
      :max_parameters=>4)
    @db.sqls.must_equal ['BEGIN',
      "INSERT INTO items (a, b) VALUES (1, 1), (2, 2)",
      "INSERT INTO items (a, b) VALUES (3, 3)",
      'COMMIT']
  end

  it "should raise when a single row exceeds the parameter limit and roll the import back" do
    proc do
      @ds.heterogeneous_insert([{:a=>1}, {:a=>2, :b=>3}], :max_parameters=>1)
    end.must_raise(Sequel::InvalidValue)
    @db.sqls.must_equal ['BEGIN', "INSERT INTO items (a) VALUES (1)", 'ROLLBACK']
  end

  it "should not execute the over-limit row or any buffered rows after it" do
    @ds = @ds.with_extend{def multi_insert_sql_strategy; :values end}
    proc do
      @ds.heterogeneous_insert([{:a=>1}, {:a=>2, :b=>3}], :max_parameters=>1)
    end.must_raise(Sequel::InvalidValue)
    @db.sqls.wont_include "INSERT INTO items (a, b) VALUES (2, 3)"
  end

  it "should identify the zero-based position of a row exceeding the parameter limit" do
    begin
      @ds.heterogeneous_insert([{:a=>1}, {:a=>2}, {:a=>3, :b=>4}], :max_parameters=>1)
    rescue Sequel::InvalidValue => e
      e.message.must_include "position 2"
    else
      raise "expected InvalidValue"
    end
  end

  it "should not execute anything before a buffered over-limit row" do
    proc do
      @ds.heterogeneous_insert([{:a=>1, :b=>2}, {:a=>3, :b=>4}], :max_parameters=>1)
    end.must_raise(Sequel::InvalidValue)
    @db.sqls.must_equal ['BEGIN', 'ROLLBACK']
  end

  it "should raise InvalidValue with the row position for non-hash elements and roll back" do
    begin
      @ds.heterogeneous_insert([{:a=>1}, [2]])
    rescue Sequel::InvalidValue => e
      e.message.must_include "position 1"
    else
      raise "expected InvalidValue"
    end
    @db.sqls.must_equal ['BEGIN', 'ROLLBACK']
  end

  it "should raise when given a non-enumerable argument" do
    proc{@ds.heterogeneous_insert(:a=>1)}.must_raise(Sequel::Error)
  end

  it "should accept an Enumerator and preserve its order" do
    @ds = @ds.with_extend{def multi_insert_sql_strategy; :values end}
    enum = Enumerator.new do |y|
      y << {:a=>1}
      y << {:a=>2, :b=>3}
      y << {:b=>4}
    end
    @ds.heterogeneous_insert(enum)
    @db.sqls.must_equal ['BEGIN',
      "INSERT INTO items (a) VALUES (1)",
      "INSERT INTO items (a, b) VALUES (2, 3)",
      "INSERT INTO items (b) VALUES (4)",
      'COMMIT']
  end

  it "should stream a large enumerator in bounded batches while inside one transaction" do
    @ds = @ds.with_extend do
      def multi_insert_sql_strategy; :values end
      def heterogeneous_insert_default_slice; 3 end
    end
    enum = Enumerator.new{|y| 7.times{|i| y << {:a=>i}} }
    @ds.heterogeneous_insert(enum)
    @db.sqls.must_equal ['BEGIN',
      "INSERT INTO items (a) VALUES (0), (1), (2)",
      "INSERT INTO items (a) VALUES (3), (4), (5)",
      "INSERT INTO items (a) VALUES (6)",
      'COMMIT']
  end

  it "should interleave enumeration with batch execution" do
    order = []
    ds = @ds.with_extend do
      define_method(:multi_insert_sql) do |columns, rows|
        order << [:flush, rows.length]
        super(columns, rows)
      end
    end
    enum = Enumerator.new do |y|
      4.times do |i|
        order << [:yield, i]
        y << {:a=>i}
      end
    end
    ds = ds.with_extend{def heterogeneous_insert_default_slice; 2 end}
    ds.heterogeneous_insert(enum, :skip_transaction=>true)
    order.must_equal [[:yield, 0], [:yield, 1], [:flush, 2],
      [:yield, 2], [:yield, 3], [:flush, 2]]
  end

  it "should roll back already executed batches when the enumerator raises" do
    enum = Enumerator.new do |y|
      y << {:a=>1}
      y << {:a=>2}
      raise "boom"
    end
    proc{@ds.heterogeneous_insert(enum, :commit_every=>1)}.must_raise(RuntimeError)
    @db.sqls.must_equal ['BEGIN',
      "INSERT INTO items (a) VALUES (1)",
      "INSERT INTO items (a) VALUES (2)",
      'ROLLBACK']
  end

  it "should roll back when the enumerator raises before the first batch is flushed" do
    enum = Enumerator.new do |y|
      y << {:a=>1}
      raise "boom"
    end
    proc{@ds.heterogeneous_insert(enum)}.must_raise(RuntimeError)
    @db.sqls.must_equal ['BEGIN', 'ROLLBACK']
  end

  it "should support :skip_transaction" do
    @ds.heterogeneous_insert([{:a=>1}], :skip_transaction=>true)
    @db.sqls.must_equal ["INSERT INTO items (a) VALUES (1)"]
  end

  it "should support the :server option" do
    @db = Sequel.mock(:servers=>{:s1=>{}}).extension(:heterogeneous_insert)
    @db[:items].heterogeneous_insert([{:a=>1}], :server=>:s1)
    @db.sqls.must_equal ['BEGIN -- s1', "INSERT INTO items (a) VALUES (1) -- s1", 'COMMIT -- s1']
  end

  it "should always return nil" do
    @ds.heterogeneous_insert([{:a=>1}], :return=>:primary_key).must_be_nil
  end
end
