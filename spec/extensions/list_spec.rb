# frozen_string_literal: true
require_relative "spec_helper"

describe "List plugin" do
  def klass(opts={})
    @db = DB
    c = Class.new(Sequel::Model(@db[:items]))
    c.class_eval do
      columns :id, :position, :scope_id, :pos
      plugin :list, opts
      self.use_transactions = false
    end
    c
  end

  before do
    @c = klass
    @o = @c.load(:id=>7, :position=>3)
    @sc = klass(:scope=>:scope_id)
    @so = @sc.load(:id=>7, :position=>3, :scope_id=>5)
    @tc = klass(:top=>0)
    @to = @tc.load(:id=>7, :position=>3)
    @db.reset
  end

  it "should default to using :position as the position field" do
    @c.position_field.must_equal :position
    @c.new.list_dataset.sql.must_equal 'SELECT * FROM items ORDER BY position'
  end

  it "should accept a :field option to modify the position field" do
    klass(:field=>:pos).position_field.must_equal :pos
  end

  it "should accept a :scope option with a symbol for a single scope column" do
    @sc.new(:scope_id=>4).list_dataset.sql.must_equal 'SELECT * FROM items WHERE (scope_id = 4) ORDER BY scope_id, position'
  end

  it "should accept a :scope option with an array of symbols for multiple scope columns" do
    ['SELECT * FROM items WHERE ((scope_id = 4) AND (pos = 3)) ORDER BY scope_id, pos, position',
     'SELECT * FROM items WHERE ((pos = 3) AND (scope_id = 4)) ORDER BY scope_id, pos, position'].
     must_include(klass(:scope=>[:scope_id, :pos]).new(:scope_id=>4, :pos=>3).list_dataset.sql)
  end

  it "should accept a :scope option with a proc for a custom list scope" do
    klass(:scope=>proc{|o| o.model.dataset.filter(:active).filter(:scope_id=>o.scope_id)}).new(:scope_id=>4).list_dataset.sql.must_equal 'SELECT * FROM items WHERE (active AND (scope_id = 4)) ORDER BY position'
  end

  it "should default top of the list to 1" do
    @c.top_of_list.must_equal 1
  end

  it "should accept a :top option to set top of the list" do
    @tc.top_of_list.must_equal 0
  end

  it "should modify the order when using the plugin" do
    c = Class.new(Sequel::Model(:items))
    c.dataset.sql.must_equal 'SELECT * FROM items'
    c.plugin :list
    c.dataset.sql.must_equal 'SELECT * FROM items ORDER BY position'
  end

  it "should be able to access the position field as a class attribute" do
    @c.position_field.must_equal :position
    klass(:field=>:pos).position_field.must_equal :pos
  end

  it "should be able to access the scope proc as a class attribute" do
    @c.scope_proc.must_be_nil
    @sc.scope_proc[@sc.new(:scope_id=>4)].sql.must_equal 'SELECT * FROM items WHERE (scope_id = 4) ORDER BY scope_id, position'
  end

  it "should work correctly in subclasses" do
    c = Class.new(klass(:scope=>:scope_id))
    c.position_field.must_equal :position
    c.scope_proc[c.new(:scope_id=>4)].sql.must_equal 'SELECT * FROM items WHERE (scope_id = 4) ORDER BY scope_id, position'
  end

  it "should have at_position return the model object at the given position" do
    @c.dataset = @c.dataset.with_fetch(:id=>1, :position=>1)
    @o.at_position(10).must_equal @c.load(:id=>1, :position=>1)
    @sc.dataset = @sc.dataset.with_fetch(:id=>2, :position=>2, :scope_id=>5)
    @so.at_position(20).must_equal @sc.load(:id=>2, :position=>2, :scope_id=>5)
    @db.sqls.must_equal ["SELECT * FROM items WHERE (position = 10) ORDER BY position LIMIT 1",
      "SELECT * FROM items WHERE ((scope_id = 5) AND (position = 20)) ORDER BY scope_id, position LIMIT 1"]
  end

  it "should have position field set to max+1 when creating if not already set" do
    @c.dataset = @c.dataset.with_autoid(1).with_fetch([[{:pos=>nil}], [{:id=>1, :position=>1}], [{:pos=>1}], [{:id=>2, :position=>2}]])
    @c.create.values.must_equal(:id=>1, :position=>1)
    @c.create.values.must_equal(:id=>2, :position=>2)
    @db.sqls.must_equal ["SELECT max(position) AS max FROM items LIMIT 1",
      "INSERT INTO items (position) VALUES (1)", 
      "SELECT * FROM items WHERE (id = 1) ORDER BY position LIMIT 1",
      "SELECT max(position) AS max FROM items LIMIT 1",
      "INSERT INTO items (position) VALUES (2)", 
      "SELECT * FROM items WHERE (id = 2) ORDER BY position LIMIT 1"]
  end

  it "should have position field set to max+1 in scope when creating if not already set" do
    @sc.dataset = @sc.dataset.with_autoid(1).with_fetch([[{:pos=>nil}], [{:id=>1, :scope_id=>1, :position=>1}], [{:pos=>1}], [{:id=>2, :scope_id=>1, :position=>2}], [{:pos=>nil}], [{:id=>3, :scope_id=>2, :position=>1}]])
    @sc.create(:scope_id=>1).values.must_equal(:id=>1, :scope_id=>1, :position=>1)
    @sc.create(:scope_id=>1).values.must_equal(:id=>2, :scope_id=>1, :position=>2)
    @sc.create(:scope_id=>2).values.must_equal(:id=>3, :scope_id=>2, :position=>1)
    @db.sqls.must_equal ["SELECT max(position) AS max FROM items WHERE (scope_id = 1) LIMIT 1",
      'INSERT INTO items (scope_id, position) VALUES (1, 1)',
      "SELECT * FROM items WHERE (id = 1) ORDER BY scope_id, position LIMIT 1",
      "SELECT max(position) AS max FROM items WHERE (scope_id = 1) LIMIT 1",
      'INSERT INTO items (scope_id, position) VALUES (1, 2)',
      "SELECT * FROM items WHERE (id = 2) ORDER BY scope_id, position LIMIT 1",
      "SELECT max(position) AS max FROM items WHERE (scope_id = 2) LIMIT 1",
      'INSERT INTO items (scope_id, position) VALUES (2, 1)',
      "SELECT * FROM items WHERE (id = 3) ORDER BY scope_id, position LIMIT 1"]
  end

  it "should have position field set to configured top value when creating first item in the list if not already set" do
    @tc.dataset = @tc.dataset.with_autoid(1).with_fetch([[{:pos=>nil}], [{:id=>1, :position=>0}], [{:pos=>0}], [{:id=>2, :position=>1}]])
    @tc.create.values.must_equal(:id=>1, :position=>0)
    @tc.create.values.must_equal(:id=>2, :position=>1)
    @db.sqls.must_equal ["SELECT max(position) AS max FROM items LIMIT 1",
      "INSERT INTO items (position) VALUES (0)",
      "SELECT * FROM items WHERE (id = 1) ORDER BY position LIMIT 1",
      "SELECT max(position) AS max FROM items LIMIT 1",
      "INSERT INTO items (position) VALUES (1)",
      "SELECT * FROM items WHERE (id = 2) ORDER BY position LIMIT 1"]
  end

  it "should update positions automatically on deletion" do
    @o.destroy
    @db.sqls.must_equal ["DELETE FROM items WHERE (id = 7)", "UPDATE items SET position = (position - 1) WHERE (position > 3)"]
  end

  it "should have last_position return the last position in the list" do
    @c.dataset = @c.dataset.with_fetch(:max=>10)
    @o.last_position.must_equal 10
    @sc.dataset = @sc.dataset.with_fetch(:max=>20)
    @so.last_position.must_equal 20
    @db.sqls.must_equal ["SELECT max(position) AS max FROM items LIMIT 1",
      "SELECT max(position) AS max FROM items WHERE (scope_id = 5) LIMIT 1"]
  end

  it "should have list_dataset return the model's dataset for non scoped lists" do
    @o.list_dataset.sql.must_equal 'SELECT * FROM items ORDER BY position'
  end

  it "should have list dataset return a scoped dataset for scoped lists" do
    @so.list_dataset.sql.must_equal 'SELECT * FROM items WHERE (scope_id = 5) ORDER BY scope_id, position'
  end

  it "should have move_down without an argument move down a single position" do
    @c.dataset = @c.dataset.with_fetch(:max=>10)
    @o.move_down.must_equal @o
    @o.position.must_equal 4
    @db.sqls.must_equal ["SELECT max(position) AS max FROM items LIMIT 1",
      "UPDATE items SET position = (position - 1) WHERE ((position >= 4) AND (position <= 4))",
      "UPDATE items SET position = 4 WHERE (id = 7)"]
  end

  it "should have move_down with an argument move down the given number of positions" do
    @c.dataset = @c.dataset.with_fetch(:max=>10)
    @o.move_down(3).must_equal @o
    @o.position.must_equal 6
    @db.sqls.must_equal ["SELECT max(position) AS max FROM items LIMIT 1",
      "UPDATE items SET position = (position - 1) WHERE ((position >= 4) AND (position <= 6))",
      "UPDATE items SET position = 6 WHERE (id = 7)"]
  end

  it "should have move_down with a negative argument move up the given number of positions" do
    @o.move_down(-1).must_equal @o
    @o.position.must_equal 2
    @db.sqls.must_equal ["UPDATE items SET position = (position + 1) WHERE ((position >= 2) AND (position < 3))",
      "UPDATE items SET position = 2 WHERE (id = 7)"]
  end

  it "should have move_to handle out of range targets" do
    @o.move_to(0)
    @o.position.must_equal 1
    @c.dataset = @c.dataset.with_fetch(:max=>10)
    @o.move_to(11)
    @o.position.must_equal 10
  end

  it "should have move_to use a transaction if the instance is configured to use transactions" do
    @o.use_transactions = true
    @o.move_to(2)
    @db.sqls.must_equal ["BEGIN",
      "UPDATE items SET position = (position + 1) WHERE ((position >= 2) AND (position < 3))",
      "UPDATE items SET position = 2 WHERE (id = 7)",
      "COMMIT"]
  end

  it "should have move_to do nothing if the target position is the same as the current position" do
    @o.use_transactions = true
    @o.move_to(@o.position).must_equal @o
    @o.position.must_equal 3
    @db.sqls.must_equal []
  end

  it "should have move to shift entries correctly between current and target if moving up" do
    @o.move_to(2)
    @db.sqls.first.must_equal "UPDATE items SET position = (position + 1) WHERE ((position >= 2) AND (position < 3))"
  end

  it "should have move to shift entries correctly between current and target if moving down" do
    @c.dataset = @c.dataset.with_fetch(:max=>10)
    @o.move_to(4)
    @db.sqls[1].must_equal "UPDATE items SET position = (position - 1) WHERE ((position >= 4) AND (position <= 4))"
  end

  it "should have move_to_bottom move the item to the last position" do
    @c.dataset = @c.dataset.with_fetch(:max=>10)
    @o.move_to_bottom
    @db.sqls.must_equal ["SELECT max(position) AS max FROM items LIMIT 1",
      "UPDATE items SET position = (position - 1) WHERE ((position >= 4) AND (position <= 10))",
      "UPDATE items SET position = 10 WHERE (id = 7)"]
  end

  it "should have move_to_top move the item to the first position" do
    @o.move_to_top
    @db.sqls.must_equal ["UPDATE items SET position = (position + 1) WHERE ((position >= 1) AND (position < 3))",
      "UPDATE items SET position = 1 WHERE (id = 7)"]
  end

  it "should have move_to_top use position 0 when :top_of_list is 0" do
    @to.move_to_top
    @db.sqls.must_equal ["UPDATE items SET position = (position + 1) WHERE ((position >= 0) AND (position < 3))",
      "UPDATE items SET position = 0 WHERE (id = 7)"]
  end

  it "should have move_up without an argument move up a single position" do
    @o.move_up.must_equal @o
    @o.position.must_equal 2
    @db.sqls.must_equal ["UPDATE items SET position = (position + 1) WHERE ((position >= 2) AND (position < 3))",
      "UPDATE items SET position = 2 WHERE (id = 7)"]
  end

  it "should have move_up with an argument move up the given number of positions" do
    @o.move_up(2).must_equal @o
    @o.position.must_equal 1
    @db.sqls.must_equal ["UPDATE items SET position = (position + 1) WHERE ((position >= 1) AND (position < 3))",
      "UPDATE items SET position = 1 WHERE (id = 7)"]
  end

  it "should have move_up with a negative argument move down the given number of positions" do
    @c.dataset = @c.dataset.with_fetch(:max=>10)
    @o.move_up(-1).must_equal @o
    @o.position.must_equal 4
    @db.sqls.must_equal ["SELECT max(position) AS max FROM items LIMIT 1",
      "UPDATE items SET position = (position - 1) WHERE ((position >= 4) AND (position <= 4))",
      "UPDATE items SET position = 4 WHERE (id = 7)"]
  end

  it "should have next return the next entry in the list if not given an argument" do
    @c.dataset = @c.dataset.with_fetch(:id=>9, :position=>4)
    @o.next.must_equal @c.load(:id=>9, :position=>4)
    @db.sqls.must_equal ["SELECT * FROM items WHERE (position = 4) ORDER BY position LIMIT 1"]
  end

  it "should have next return the entry the given number of positions below the instance if given an argument" do
    @c.dataset = @c.dataset.with_fetch(:id=>9, :position=>5)
    @o.next(2).must_equal @c.load(:id=>9, :position=>5)
    @db.sqls.must_equal ["SELECT * FROM items WHERE (position = 5) ORDER BY position LIMIT 1"]
  end

  it "should have next return receiver if given zero" do
    @o.next(0).must_be_same_as @o
    @db.sqls.must_equal []
  end

  it "should have next return a previous entry if given a negative argument" do
    @c.dataset = @c.dataset.with_fetch(:id=>9, :position=>2)
    @o.next(-1).must_equal @c.load(:id=>9, :position=>2)
    @db.sqls.must_equal ["SELECT * FROM items WHERE (position = 2) ORDER BY position LIMIT 1"]
  end

  it "should have position_value return the value of the position field" do
    @o.position_value.must_equal 3
  end

  it "should have prev return the previous entry in the list if not given an argument" do
    @c.dataset = @c.dataset.with_fetch(:id=>9, :position=>2)
    @o.prev.must_equal @c.load(:id=>9, :position=>2)
    @db.sqls.must_equal ["SELECT * FROM items WHERE (position = 2) ORDER BY position LIMIT 1"]
  end

  it "should have prev return the entry the given number of positions above the instance if given an argument" do
    @c.dataset = @c.dataset.with_fetch(:id=>9, :position=>1)
    @o.prev(2).must_equal @c.load(:id=>9, :position=>1)
    @db.sqls.must_equal ["SELECT * FROM items WHERE (position = 1) ORDER BY position LIMIT 1"]
  end

  it "should have prev return a following entry if given a negative argument" do
    @c.dataset = @c.dataset.with_fetch(:id=>9, :position=>4)
    @o.prev(-1).must_equal @c.load(:id=>9, :position=>4)
    @db.sqls.must_equal ["SELECT * FROM items WHERE (position = 4) ORDER BY position LIMIT 1"]
  end

  it "should work correctly with validation on position" do
    @c.class_eval do
      def validate
        super
        errors.add(:position, "not set") unless position
      end
    end
    @c.create
    @db.sqls.must_equal ["SELECT max(position) AS max FROM items LIMIT 1", "INSERT INTO items (position) VALUES (2)", "SELECT * FROM items WHERE (id = 10) ORDER BY position LIMIT 1"]
  end

  it "should move multiple consecutive entries upward with a fixed number of bulk updates" do
    db = sqlite_list_database
    item = sqlite_list_model(db)
    5.times { |id| item.insert(id: id + 1, scope_id: 1, position: id + 1) }

    item.move_many([4, 5], 2).must_equal 4
    item.where(scope_id: 1).order(:position).select_map(:id).must_equal [1, 4, 5, 2, 3]
    db.update_count.must_equal 3
  end

  it "should move multiple consecutive entries downward with a fixed number of bulk updates" do
    db = sqlite_list_database
    item = sqlite_list_model(db)
    5.times { |id| item.insert(id: id + 1, scope_id: 1, position: id + 1) }

    item.move_many([1, 2], 5).must_equal 5
    item.where(scope_id: 1).order(:position).select_map(:id).must_equal [3, 4, 5, 1, 2]
    db.update_count.must_equal 3
  end

  it "should move multiple entries to another scope and preserve unselected relative order" do
    db = sqlite_list_database
    item = sqlite_list_model(db)
    5.times { |id| item.insert(id: id + 1, scope_id: 1, position: id + 1) }
    3.times { |id| item.insert(id: id + 6, scope_id: 2, position: id + 1) }

    item.move_many([2, 1], 2, scope_id: 2).must_equal 7
    item.where(scope_id: 1).order(:position).select_map(:id).must_equal [3, 4, 5]
    item.where(scope_id: 2).order(:position).select_map(:id).must_equal [6, 2, 1, 7, 8]
    db.update_count.must_equal 3
  end

  it "should move every entry in a source scope to another scope" do
    db = sqlite_list_database
    item = sqlite_list_model(db)
    3.times { |id| item.insert(id: id + 1, scope_id: 1, position: id + 1) }
    2.times { |id| item.insert(id: id + 4, scope_id: 2, position: id + 1) }

    item.move_many([2, 1, 3], 2, scope_id: 2).must_equal 4
    item.where(scope_id: 1).count.must_equal 0
    item.where(scope_id: 2).order(:position).select_map(:id).must_equal [4, 2, 1, 3, 5]
    db.update_count.must_equal 3
  end

  it "should keep selected entries ordered even when they exchange positions" do
    db = sqlite_list_database
    item = sqlite_list_model(db)
    5.times { |id| item.insert(id: id + 1, scope_id: 1, position: id + 1) }

    item.move_many([2, 1], 2).must_equal 2
    item.where(scope_id: 1).order(:position).select_map(:id).must_equal [3, 2, 1, 4, 5]
    db.update_count.must_equal 3
  end

  it "should not leave temporary positions when a target constraint fails" do
    db = sqlite_list_database("scope_id <> 2 OR position <> 1")
    item = sqlite_list_model(db)
    item.insert(id: 1, scope_id: 1, position: 1)
    item.insert(id: 2, scope_id: 1, position: 2)

    proc { item.move_many([1, 2], 1, scope_id: 2) }.must_raise(Sequel::ConstraintViolation)
    item.order(:scope_id, :position).map { |row| [row.id, row.scope_id, row.position] }.
      must_equal [[1, 1, 1], [2, 1, 2]]
  end

  it "should reject invalid move_many arguments before changing rows" do
    db = sqlite_list_database
    item = sqlite_list_model(db)
    5.times { |id| item.insert(id: id + 1, scope_id: 1, position: id + 1) }
    item.insert(id: 6, scope_id: 2, position: 1)

    proc { item.move_many([1, 1], 2) }.must_raise(Sequel::Error)
    proc { item.move_many([1, 999], 2) }.must_raise(Sequel::Error)
    proc { item.move_many([1, 6], 2) }.must_raise(Sequel::Error)
    db.update_count.must_equal 0
  end

  it "should not update rows when move_many does not change the list" do
    db = sqlite_list_database
    item = sqlite_list_model(db)
    5.times { |id| item.insert(id: id + 1, scope_id: 1, position: id + 1) }

    item.move_many([1, 2], 1).must_equal 0
    item.where(scope_id: 1).order(:position).select_map(:id).must_equal [1, 2, 3, 4, 5]
    db.update_count.must_equal 0
  end

  private

  def sqlite_list_database(check_constraint = nil)
    db = Sequel.sqlite
    db.create_table :items do
      primary_key :id
      Integer :scope_id, null: false
      Integer :position, null: false
      unique [:scope_id, :position]
      check check_constraint if check_constraint
    end
    def db.update_count
      @update_count ||= 0
    end
    def db._execute(type, sql, opts=OPTS, &block)
      @update_count ||= 0
      @update_count += 1 if type == :update
      super
    end
    db
  end

  def sqlite_list_model(db)
    Class.new(Sequel::Model(db[:items])).tap do |model|
      model.plugin :list, scope: :scope_id
    end
  end
end
