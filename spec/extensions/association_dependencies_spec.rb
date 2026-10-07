# frozen_string_literal: true
require_relative "spec_helper"

describe "AssociationDependencies plugin" do
  before do
    @mods = []
    @c = Class.new(Sequel::Model)
    @c.plugin :association_dependencies
    @Artist = Class.new(@c).set_dataset(:artists)
    @Artist.dataset = @Artist.dataset.with_fetch(:id=>2, :name=>'Ar')
    @Album = Class.new(@c).set_dataset(:albums)
    @Album.dataset = @Album.dataset.with_fetch(:id=>1, :name=>'Al', :artist_id=>2)
    @Artist.columns :id, :name
    @Album.columns :id, :name, :artist_id
    @Artist.one_to_many :albums, :class=>@Album, :key=>:artist_id
    @Artist.one_to_one :first_album, :class=>@Album, :key=>:artist_id, :conditions=>{:position=>1}
    @Artist.many_to_many :other_artists, :class=>@Artist, :join_table=>:aoa, :left_key=>:l, :right_key=>:r
    @Album.many_to_one :artist, :class=>@Artist
    DB.reset
  end

  it "should allow destroying associated many_to_one associated object" do
    @Album.add_association_dependencies :artist=>:destroy
    @Album.load(:id=>1, :name=>'Al', :artist_id=>2).destroy
    DB.sqls.must_equal ['DELETE FROM albums WHERE id = 1', 'SELECT * FROM artists WHERE (artists.id = 2) LIMIT 1', 'DELETE FROM artists WHERE id = 2']
  end

  it "should allow deleting associated many_to_one associated object" do
    @Album.add_association_dependencies :artist=>:delete
    @Album.load(:id=>1, :name=>'Al', :artist_id=>2).destroy
    DB.sqls.must_equal ['DELETE FROM albums WHERE id = 1', 'DELETE FROM artists WHERE (artists.id = 2)']
  end
  
  it "should allow destroying associated one_to_one associated object" do
    @Artist.add_association_dependencies :first_album=>:destroy
    @Artist.load(:id=>2, :name=>'Ar').destroy
    DB.sqls.must_equal ['SELECT * FROM albums WHERE ((position = 1) AND (albums.artist_id = 2)) LIMIT 1', 'DELETE FROM albums WHERE id = 1', 'DELETE FROM artists WHERE id = 2']
  end

  it "should allow deleting associated one_to_one associated object" do
    @Artist.add_association_dependencies :first_album=>:delete
    @Artist.load(:id=>2, :name=>'Ar').destroy
    DB.sqls.must_equal ['DELETE FROM albums WHERE ((position = 1) AND (albums.artist_id = 2))', 'DELETE FROM artists WHERE id = 2']
  end

  it "should allow destroying associated one_to_many objects" do
    @Artist.add_association_dependencies :albums=>:destroy
    @Artist.load(:id=>2, :name=>'Ar').destroy
    DB.sqls.must_equal ['SELECT * FROM albums WHERE (albums.artist_id = 2)', 'DELETE FROM albums WHERE id = 1', 'DELETE FROM artists WHERE id = 2']
  end

  it "should allow deleting associated one_to_many objects" do
    @Artist.add_association_dependencies :albums=>:delete
    @Artist.load(:id=>2, :name=>'Ar').destroy
    DB.sqls.must_equal ['DELETE FROM albums WHERE (albums.artist_id = 2)', 'DELETE FROM artists WHERE id = 2']
  end
  
  it "should allow nullifying associated one_to_one objects" do
    @Artist.add_association_dependencies :first_album=>:nullify
    @Artist.load(:id=>2, :name=>'Ar').destroy
    DB.sqls.must_equal ['UPDATE albums SET artist_id = NULL WHERE ((position = 1) AND (artist_id = 2))', 'DELETE FROM artists WHERE id = 2']
  end

  it "should allow nullifying associated one_to_many objects" do
    @Artist.add_association_dependencies :albums=>:nullify
    @Artist.load(:id=>2, :name=>'Ar').destroy
    DB.sqls.must_equal ['UPDATE albums SET artist_id = NULL WHERE (artist_id = 2)', 'DELETE FROM artists WHERE id = 2']
  end

  it "should allow nullifying associated many_to_many associations" do
    @Artist.add_association_dependencies :other_artists=>:nullify
    @Artist.load(:id=>2, :name=>'Ar').destroy
    DB.sqls.must_equal ['DELETE FROM aoa WHERE (l = 2)', 'DELETE FROM artists WHERE id = 2']
  end

  it "should not allow modifications if class is frozen" do
    @Artist.add_association_dependencies :other_artists=>:nullify
    @Artist.freeze
    proc{@Artist.add_association_dependencies :albums=>:nullify}.must_raise RuntimeError, TypeError
    @Artist.association_dependencies.frozen?.must_equal true
    @Artist.association_dependencies[:before_nullify].frozen?.must_equal true
  end

  it "should raise an error if attempting to nullify a many_to_one association" do
    proc{@Album.add_association_dependencies :artist=>:nullify}.must_raise(Sequel::Error)
  end

  it "should raise an error if using an unrecognized dependence action" do
    proc{@Album.add_association_dependencies :artist=>:blah}.must_raise(Sequel::Error)
  end

  it "should raise an error if a nonexistent association is used" do
    proc{@Album.add_association_dependencies :blah=>:delete}.must_raise(Sequel::Error)
  end

  it "should raise an error if a invalid association type is used" do
    @Artist.plugin :many_through_many
    @Artist.many_through_many :other_albums, [[:id, :id, :id]]
    proc{@Artist.add_association_dependencies :other_albums=>:nullify}.must_raise(Sequel::Error)
  end

  it "should raise an error if using a many_to_many association type without nullify" do
    proc{@Artist.add_association_dependencies :other_artists=>:delete}.must_raise(Sequel::Error)
  end

  it "should allow specifying association dependencies in the plugin call" do
    @Album.plugin :association_dependencies, :artist=>:destroy
    @Album.load(:id=>1, :name=>'Al', :artist_id=>2).destroy
    DB.sqls.must_equal ['DELETE FROM albums WHERE id = 1', 'SELECT * FROM artists WHERE (artists.id = 2) LIMIT 1', 'DELETE FROM artists WHERE id = 2']
  end

  it "should work with subclasses" do
    c = Class.new(@Album)
    c.add_association_dependencies :artist=>:destroy
    c.load(:id=>1, :name=>'Al', :artist_id=>2).destroy
    DB.sqls.must_equal ['DELETE FROM albums WHERE id = 1', 'SELECT * FROM artists WHERE (artists.id = 2) LIMIT 1', 'DELETE FROM artists WHERE id = 2']

    @Album.load(:id=>1, :name=>'Al', :artist_id=>2).destroy
    DB.sqls.must_equal ['DELETE FROM albums WHERE id = 1']

    @Album.add_association_dependencies :artist=>:destroy
    c2 = Class.new(@Album)
    c2.load(:id=>1, :name=>'Al', :artist_id=>2).destroy
    DB.sqls.must_equal ['DELETE FROM albums WHERE id = 1', 'SELECT * FROM artists WHERE (artists.id = 2) LIMIT 1', 'DELETE FROM artists WHERE id = 2']
  end

  it "should restrict destroying object with associated one_to_many objects" do
    @Artist.add_association_dependencies :albums=>:restrict
    a = @Artist.load(:id=>2, :name=>'Ar')
    e = proc{a.destroy}.must_raise(Sequel::Plugins::AssociationDependencies::RestrictViolation)
    e.model.must_equal a
    e.violations.map{|path, _, _| path}.must_equal [[:albums]]
    e.violations.first[2].must_equal [1]
    e.message.must_include('cannot destroy')
    e.message.must_include('albums')
    DB.sqls.must_equal ['BEGIN', 'SELECT id FROM albums WHERE (albums.artist_id = 2) LIMIT 5', 'ROLLBACK']
  end

  it "should restrict destroying object with associated one_to_one objects" do
    @Artist.add_association_dependencies :first_album=>:restrict
    proc{@Artist.load(:id=>2, :name=>'Ar').destroy}.must_raise(Sequel::Plugins::AssociationDependencies::RestrictViolation)
    DB.sqls.must_equal ['BEGIN', 'SELECT id FROM albums WHERE ((position = 1) AND (albums.artist_id = 2)) LIMIT 5', 'ROLLBACK']
  end

  it "should restrict destroying object with associated many_to_one objects" do
    @Album.add_association_dependencies :artist=>:restrict
    proc{@Album.load(:id=>1, :name=>'Al', :artist_id=>2).destroy}.must_raise(Sequel::Plugins::AssociationDependencies::RestrictViolation)
    DB.sqls.must_equal ['BEGIN', 'SELECT id FROM artists WHERE (artists.id = 2) LIMIT 5', 'ROLLBACK']
  end

  it "should not restrict destroying object without associated objects" do
    @Artist.add_association_dependencies :albums=>:restrict
    @Album.dataset = @Album.dataset.with_fetch([])
    @Artist.load(:id=>2, :name=>'Ar').destroy
    DB.sqls.must_equal ['BEGIN', 'SELECT id FROM albums WHERE (albums.artist_id = 2) LIMIT 5', 'DELETE FROM artists WHERE id = 2', 'COMMIT']
  end

  it "should run the restrict check and the deletion in the same transaction" do
    @Artist.use_transactions = true
    @Artist.add_association_dependencies :albums=>:restrict
    @Album.dataset = @Album.dataset.with_fetch([])
    @Artist.load(:id=>2, :name=>'Ar').destroy
    DB.sqls.must_equal ['BEGIN', 'SELECT id FROM albums WHERE (albums.artist_id = 2) LIMIT 5', 'DELETE FROM artists WHERE id = 2', 'COMMIT']
  end

  it "should check all dependency branches before deleting any branch" do
    fan = Class.new(@c).set_dataset(:fans)
    fan.dataset = fan.dataset.with_fetch(:id=>5, :artist_id=>2)
    fan.columns :id, :artist_id
    @Artist.one_to_many :fans, :class=>fan, :key=>:artist_id
    @Artist.add_association_dependencies :albums=>:destroy, :fans=>:restrict
    proc{@Artist.load(:id=>2, :name=>'Ar').destroy}.must_raise(Sequel::Plugins::AssociationDependencies::RestrictViolation)
    DB.sqls.must_equal ['BEGIN', 'SELECT id FROM fans WHERE (fans.artist_id = 2) LIMIT 5', 'ROLLBACK']
  end

  it "should not run destroy hooks or make changes when restrict is violated" do
    @Artist.add_association_dependencies :albums=>:restrict
    hooks = []
    @Artist.send(:define_method, :before_destroy){hooks << :before; super()}
    @Artist.send(:define_method, :after_destroy){hooks << :after; super()}
    proc{@Artist.load(:id=>2, :name=>'Ar').destroy}.must_raise(Sequel::Plugins::AssociationDependencies::RestrictViolation)
    hooks.must_equal []
    DB.sqls.grep(/DELETE|UPDATE|INSERT/).must_equal []
  end

  it "should check restrict dependencies of recursively destroyed associations" do
    track = Class.new(@c).set_dataset(:tracks)
    track.dataset = track.dataset.with_fetch(:id=>3, :album_id=>1)
    track.columns :id, :album_id
    @Album.one_to_many :tracks, :class=>track, :key=>:album_id
    @Album.add_association_dependencies :tracks=>:restrict
    @Artist.add_association_dependencies :albums=>:destroy
    e = proc{@Artist.load(:id=>2, :name=>'Ar').destroy}.must_raise(Sequel::Plugins::AssociationDependencies::RestrictViolation)
    e.violations.map{|path, _, _| path}.must_equal [[:albums, :tracks]]
    e.violations.first[2].must_equal [3]
    DB.sqls.must_equal ['BEGIN', 'SELECT * FROM albums WHERE (albums.artist_id = 2)', 'SELECT id FROM tracks WHERE (tracks.album_id = 1) LIMIT 5', 'ROLLBACK']
  end

  it "should terminate with a finite path for cyclic dependencies" do
    track = Class.new(@c).set_dataset(:tracks)
    track.dataset = track.dataset.with_fetch(:id=>3, :album_id=>1)
    track.columns :id, :album_id
    @Album.one_to_many :tracks, :class=>track, :key=>:album_id
    @Album.add_association_dependencies :tracks=>:restrict, :artist=>:destroy
    @Artist.add_association_dependencies :albums=>:destroy
    e = proc{@Artist.load(:id=>2, :name=>'Ar').destroy}.must_raise(Sequel::Plugins::AssociationDependencies::RestrictViolation)
    e.violations.map{|path, _, _| path}.must_equal [[:albums, :tracks]]
    DB.sqls.must_equal ['BEGIN', 'SELECT * FROM albums WHERE (albums.artist_id = 2)', 'SELECT id FROM tracks WHERE (tracks.album_id = 1) LIMIT 5', 'SELECT * FROM artists WHERE (artists.id = 2) LIMIT 1', 'ROLLBACK']
  end

  it "should check shared dependent objects only once" do
    track = Class.new(@c).set_dataset(:tracks)
    track.dataset = track.dataset.with_fetch(:id=>3, :album_id=>1)
    track.columns :id, :album_id
    @Album.one_to_many :tracks, :class=>track, :key=>:album_id
    @Album.add_association_dependencies :tracks=>:restrict
    @Artist.add_association_dependencies :albums=>:destroy, :first_album=>:destroy
    proc{@Artist.load(:id=>2, :name=>'Ar').destroy}.must_raise(Sequel::Plugins::AssociationDependencies::RestrictViolation)
    DB.sqls.select{|s| s =~ /FROM tracks/}.length.must_equal 1
  end

  it "should identify objects by all columns of composite primary keys when checking" do
    node = Class.new(@c).set_dataset(:nodes)
    node.dataset = node.dataset.with_fetch([{:a=>1, :b=>1, :artist_id=>2}, {:a=>1, :b=>2, :artist_id=>2}])
    node.columns :a, :b, :artist_id
    node.set_primary_key [:a, :b]
    entry = Class.new(@c).set_dataset(:entries)
    entry.dataset = entry.dataset.with_fetch(:id=>9, :na=>1, :nb=>1)
    entry.columns :id, :na, :nb
    node.one_to_many :entries, :class=>entry, :key=>[:na, :nb]
    node.add_association_dependencies :entries=>:restrict
    @Artist.one_to_many :nodes, :class=>node, :key=>:artist_id
    @Artist.add_association_dependencies :nodes=>:destroy
    e = proc{@Artist.load(:id=>2, :name=>'Ar').destroy}.must_raise(Sequel::Plugins::AssociationDependencies::RestrictViolation)
    e.violations.length.must_equal 2
    sqls = DB.sqls
    sqls.must_include 'SELECT id FROM entries WHERE ((entries.na = 1) AND (entries.nb = 1)) LIMIT 5'
    sqls.must_include 'SELECT id FROM entries WHERE ((entries.na = 1) AND (entries.nb = 2)) LIMIT 5'
  end

  it "should use association datasets and not cached associations when checking" do
    @Artist.add_association_dependencies :albums=>:restrict
    a = @Artist.load(:id=>2, :name=>'Ar')
    a.albums.must_equal [@Album.load(:id=>1, :name=>'Al', :artist_id=>2)]
    DB.reset
    proc{a.destroy}.must_raise(Sequel::Plugins::AssociationDependencies::RestrictViolation)
    DB.sqls.must_equal ['BEGIN', 'SELECT id FROM albums WHERE (albums.artist_id = 2) LIMIT 5', 'ROLLBACK']
  end

  it "should raise an error if attempting to restrict a many_to_many association" do
    proc{@Artist.add_association_dependencies :other_artists=>:restrict}.must_raise(Sequel::Error)
  end

  it "should allow specifying restrict association dependencies in the plugin call" do
    @Album.plugin :association_dependencies, :artist=>:restrict
    proc{@Album.load(:id=>1, :name=>'Al', :artist_id=>2).destroy}.must_raise(Sequel::Plugins::AssociationDependencies::RestrictViolation)
    DB.sqls.must_equal ['BEGIN', 'SELECT id FROM artists WHERE (artists.id = 2) LIMIT 5', 'ROLLBACK']
  end

  it "should inherit restrict dependencies in subclasses" do
    @Artist.add_association_dependencies :albums=>:restrict
    c = Class.new(@Artist)
    proc{c.load(:id=>2, :name=>'Ar').destroy}.must_raise(Sequel::Plugins::AssociationDependencies::RestrictViolation)
    DB.sqls.must_equal ['BEGIN', 'SELECT id FROM albums WHERE (albums.artist_id = 2) LIMIT 5', 'ROLLBACK']
  end

  it "should freeze association dependency reflections when freezing model class" do
    @Artist.add_association_dependencies :albums=>:restrict
    @Artist.freeze
    @Artist.association_dependency_reflections.frozen?.must_equal true
    @Artist.association_dependency_reflections[:restrict].frozen?.must_equal true
  end
end

begin
  require 'sqlite3'
rescue LoadError
  # Skip tests using a real SQLite database if the sqlite3 gem is not available
else
  describe "AssociationDependencies plugin restrict action on SQLite" do
    before do
      @db = Sequel.sqlite
      @db.create_table(:artists){primary_key :id; String :name}
      @db.create_table(:albums){primary_key :id; Integer :artist_id}
      @db.create_table(:fans){primary_key :id; Integer :artist_id}
      c = Class.new(Sequel::Model(@db))
      c.plugin :association_dependencies
      @Artist = Class.new(c).set_dataset(:artists)
      @Album = Class.new(c).set_dataset(:albums)
      @Fan = Class.new(c).set_dataset(:fans)
      @Artist.one_to_many :albums, :class=>@Album, :key=>:artist_id
      @Artist.one_to_many :fans, :class=>@Fan, :key=>:artist_id
      @Artist.add_association_dependencies :albums=>:destroy, :fans=>:restrict
    end

    after do
      @db.disconnect
    end

    it "should not delete any branch or run hooks when another branch restricts" do
      aid = @Artist.insert(:name=>'a')
      @Album.insert(:artist_id=>aid)
      @Fan.insert(:artist_id=>aid)
      hooks = []
      @Artist.send(:define_method, :before_destroy){hooks << :before; super()}
      @Artist.send(:define_method, :after_destroy){hooks << :after; super()}
      a = @Artist[aid]
      proc{a.destroy}.must_raise(Sequel::Plugins::AssociationDependencies::RestrictViolation)
      hooks.must_equal []
      @Artist.count.must_equal 1
      @Album.count.must_equal 1
      @Fan.count.must_equal 1

      @Fan.where(:artist_id=>aid).delete
      a.destroy
      @Artist.count.must_equal 0
      @Album.count.must_equal 0
    end

    it "should include a limited number of example keys in the violation" do
      aid = @Artist.insert(:name=>'a')
      7.times{@Fan.insert(:artist_id=>aid)}
      e = proc{@Artist[aid].destroy}.must_raise(Sequel::Plugins::AssociationDependencies::RestrictViolation)
      e.violations.map{|path, _, _| path}.must_equal [[:fans]]
      e.violations.first[2].length.must_equal 5
    end
  end
end
