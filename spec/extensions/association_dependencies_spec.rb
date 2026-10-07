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

  it "should accept :restrict as a dependence action" do
    @Album.add_association_dependencies :artist=>:restrict
    @Album.association_dependencies[:after_restrict].must_equal [:artist]
    @Artist.add_association_dependencies :albums=>:restrict, :first_album=>:restrict, :other_artists=>:restrict
    @Artist.association_dependencies[:before_restrict].must_equal [:albums, :first_album, :other_artists]
  end

  it "should not issue any extra queries for models whose destroy graph has no restrict dependencies" do
    @Album.add_association_dependencies :artist=>:destroy
    @Album.load(:id=>1, :name=>'Al', :artist_id=>2).destroy
    DB.sqls.must_equal ['DELETE FROM albums WHERE id = 1', 'SELECT * FROM artists WHERE (artists.id = 2) LIMIT 1', 'DELETE FROM artists WHERE id = 2']
  end

  it "should raise AssociationDependencyRestriction before any delete when a before restrict association has rows" do
    @Artist.add_association_dependencies :albums=>:restrict
    proc{@Artist.load(:id=>2, :name=>'Ar').destroy}.must_raise Sequel::AssociationDependencyRestriction
    DB.sqls.must_equal ['SELECT id FROM albums WHERE (albums.artist_id = 2) LIMIT 3']
  end

  it "should raise AssociationDependencyRestriction for a one_to_one association with an associated object" do
    @Artist.add_association_dependencies :first_album=>:restrict
    begin
      @Artist.load(:id=>2, :name=>'Ar').destroy
    rescue Sequel::AssociationDependencyRestriction => e
      e.root_object.must_equal @Artist.load(:id=>2, :name=>'Ar')
      e.association_path.must_equal 'first_album'
      e.example_keys.must_equal [{:id=>1}]
      e.message.must_include 'cannot destroy'
      e.message.must_include 'first_album'
    else
      raise "expected restriction"
    end
    DB.sqls.must_equal ['SELECT id FROM albums WHERE ((position = 1) AND (albums.artist_id = 2)) LIMIT 3']
  end

  it "should raise AssociationDependencyRestriction for a many_to_one association with an associated object" do
    @Album.add_association_dependencies :artist=>:restrict
    begin
      @Album.load(:id=>1, :name=>'Al', :artist_id=>2).destroy
    rescue Sequel::AssociationDependencyRestriction => e
      e.association_path.must_equal 'artist'
      e.example_keys.must_equal [{:id=>2}]
    else
      raise "expected restriction"
    end
    DB.sqls.must_equal ['SELECT id FROM artists WHERE (artists.id = 2) LIMIT 3']
  end

  it "should raise AssociationDependencyRestriction for a many_to_many association with related rows" do
    @Artist.add_association_dependencies :other_artists=>:restrict
    proc{@Artist.load(:id=>2, :name=>'Ar').destroy}.must_raise Sequel::AssociationDependencyRestriction
    DB.sqls.must_equal ['SELECT id FROM artists INNER JOIN aoa ON (aoa.r = artists.id) WHERE (aoa.l = 2) LIMIT 3']
  end

  it "should allow destroying when a restrict association has no associated rows" do
    @EmptyAlbum = Class.new(@c).set_dataset(:empty_albums)
    @EmptyAlbum.dataset = @EmptyAlbum.dataset.with_fetch([])
    @EmptyAlbum.columns :id, :name, :artist_id
    @Artist.one_to_many :empty_albums, :class=>@EmptyAlbum, :key=>:artist_id
    @Artist.add_association_dependencies :empty_albums=>:restrict
    @Artist.load(:id=>2, :name=>'Ar').destroy
    DB.sqls.must_equal ['SELECT id FROM empty_albums WHERE (empty_albums.artist_id = 2) LIMIT 3', 'DELETE FROM artists WHERE id = 2']
  end

  it "should check restrict dependencies reached through a destroy dependency graph" do
    # Artist destroys albums; Album restricts tags (not a known association here,
    # set it up through a third model)
    @Tag = Class.new(@c).set_dataset(:tags)
    @Tag.dataset = @Tag.dataset.with_fetch(:id=>9, :album_id=>1)
    @Tag.columns :id, :album_id
    @Album.one_to_many :tags, :class=>@Tag, :key=>:album_id
    @Album.add_association_dependencies :tags=>:restrict
    @Artist.add_association_dependencies :albums=>:destroy
    begin
      @Artist.load(:id=>2, :name=>'Ar').destroy
    rescue Sequel::AssociationDependencyRestriction => e
      e.association_path.must_equal 'albums -> tags'
      e.example_keys.must_equal [{:id=>9}]
    else
      raise "expected restriction"
    end
    DB.sqls.must_equal [
      'SELECT * FROM albums WHERE (albums.artist_id = 2)',
      'SELECT id FROM tags WHERE (tags.album_id = 1) LIMIT 3'
    ]
  end

  it "should not walk graphs reachable only through delete or nullify dependencies" do
    @Tag = Class.new(@c).set_dataset(:tags)
    @Tag.columns :id, :album_id
    @Album.one_to_many :tags, :class=>@Tag, :key=>:album_id
    @Album.add_association_dependencies :tags=>:restrict
    @Artist.add_association_dependencies :albums=>:delete
    @Artist.restriction_graph?.must_equal false
    @Artist.load(:id=>2, :name=>'Ar').destroy
    DB.sqls.must_equal ['DELETE FROM albums WHERE (albums.artist_id = 2)', 'DELETE FROM artists WHERE id = 2']
  end

  it "should not invoke before_destroy hooks or writes of other branches when one branch blocks" do
    @Tag = Class.new(@c).set_dataset(:tags)
    @Tag.dataset = @Tag.dataset.with_fetch(:id=>9, :album_id=>1)
    @Tag.columns :id, :album_id
    @Album.one_to_many :tags, :class=>@Tag, :key=>:album_id
    @Album.add_association_dependencies :tags=>:restrict
    @Artist.add_association_dependencies :albums=>:destroy
    @Artist.one_to_one :second_album, :class=>@Album, :key=>:artist_id, :conditions=>{:position=>2}
    @Artist.add_association_dependencies :second_album=>:delete
    called = []
    @Artist.define_method(:before_destroy){ called << :before_destroy; super }
    proc{@Artist.load(:id=>2, :name=>'Ar').destroy}.must_raise Sequel::AssociationDependencyRestriction
    called.must_equal []
    DB.sqls.wont_include 'DELETE FROM albums WHERE ((position = 2) AND (albums.artist_id = 2))'
  end
end
