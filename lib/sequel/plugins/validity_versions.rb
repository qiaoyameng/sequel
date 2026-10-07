# frozen-string-literal: true

module Sequel
  module Plugins
    # The validity_versions plugin turns a model into a collection of
    # business-time (valid-time) versions.  Each logical key can have
    # multiple version rows, each valid for a half-open interval
    # [valid_from, valid_to).  A +nil+ valid_to represents infinity.
    #
    # The intervals are business time, assigned explicitly by the
    # application; they are never derived from database update timestamps.
    #
    # Basic example:
    #
    #   class Price < Sequel::Model(:prices)
    #     plugin :validity_versions
    #   end
    #
    #   Price.create_version('sku-1', Time.utc(2026, 1, 1), Time.utc(2026, 6, 1), amount: 10)
    #   Price.as_of('sku-1', Time.utc(2026, 3, 1))  # => version with amount 10
    #
    #   # Revise the amount over part of the interval, splitting the
    #   # covered versions and keeping the old values on both sides:
    #   Price.revise('sku-1', Time.utc(2026, 3, 1), Time.utc(2026, 4, 1), amount: 12)
    #
    # The table used by the model must have columns for the logical key,
    # the interval bounds, and an integer lock column used for optimistic
    # concurrency control:
    #
    #   DB.create_table(:prices) do
    #     primary_key :id
    #     String :key, null: false
    #     Time :valid_from, null: false
    #     Time :valid_to          # nil means infinity
    #     Integer :lock_version, null: false, default: 0
    #     # ... content columns ...
    #   end
    #
    # Options:
    # :key :: Column holding the logical key (default: :key)
    # :from :: Column holding the start of the valid interval (default: :valid_from)
    # :to :: Column holding the end of the valid interval (default: :valid_to)
    # :lock_column :: Integer column used for optimistic concurrency
    #                 control (default: :lock_version)
    # :merge_adjacent :: Whether adjacent versions of the same logical key
    #                    with identical content are merged into a single
    #                    version when creating or revising versions
    #                    (default: false)
    #
    # The plugin rejects empty intervals (valid_to == valid_from), inverted
    # intervals (valid_to < valid_from), and versions that would overlap
    # existing history for the same logical key, by raising
    # ValidityVersions::InvalidInterval or ValidityVersions::OverlappingVersions.
    #
    # Revisions spanning multiple existing versions are applied atomically
    # inside a transaction; if any part fails, all original intervals are
    # preserved.  Concurrent revisions of the same logical key are detected
    # using the lock column: a revision planned against state that has since
    # changed raises ValidityVersions::Conflict instead of silently
    # overwriting the other revision's changes.
    module ValidityVersions
      # Base error class for the validity_versions plugin.
      class Error < Sequel::Error; end

      # Raised when a version has a nil valid_from, an empty interval
      # (valid_to == valid_from), or an inverted interval
      # (valid_to < valid_from).
      class InvalidInterval < Error; end

      # Raised when a version would overlap existing history for the same
      # logical key.
      class OverlappingVersions < Error; end

      # Raised when a planned revision is committed after another revision
      # has modified the same logical key's versions.
      class Conflict < Error; end

      def self.configure(model, opts=OPTS)
        model.validity_versions_opts = {
          :key => opts.fetch(:key, :key),
          :from => opts.fetch(:from, :valid_from),
          :to => opts.fetch(:to, :valid_to),
          :lock_column => opts.fetch(:lock_column, :lock_version),
          :merge_adjacent => opts.fetch(:merge_adjacent, false)
        }.freeze
      end

      # A planned revision of a logical key over a [from, to) interval.
      # Captures the currently covered versions when created, and applies
      # the revision atomically when committed, detecting concurrent
      # modifications via the lock column.
      class Revision
        attr_reader :model, :key, :valid_from, :valid_to, :attributes

        def initialize(model, key, valid_from, valid_to, attributes)
          @model = model
          @key = key
          @valid_from = valid_from
          @valid_to = valid_to
          @attributes = attributes
          model.send(:validate_validity_interval!, valid_from, valid_to)
          model.send(:check_revision_attributes!, attributes)
          @covered = model.versions_of(key).validity_overlapping(valid_from, valid_to).all
        end

        # Apply the revision inside a transaction.  Splits every covered
        # version so the parts outside [valid_from, valid_to) keep their
        # old values, removes the covered parts, and inserts a single new
        # version with the revised attributes.  Returns the new version.
        # Raises ValidityVersions::Conflict if the versions covered when
        # the revision was planned have since changed.
        def commit
          model.db.transaction do
            version = apply
            model.send(:merge_validity_neighbors!, version) if model.validity_merge_adjacent?
            version
          end
        end

        private

        def apply
          from_col = model.validity_from_column
          to_col = model.validity_to_column
          @covered.each do |row|
            old_from = row.get_column_value(from_col)
            old_to = row.get_column_value(to_col)
            left = old_from < valid_from
            right = valid_to && (old_to.nil? || old_to > valid_to)
            if left && right
              remnant = model.send(:validity_remnant_attributes, row)
              model.send(:guarded_validity_update!, row, to_col=>valid_from)
              model.send(:insert_validity_version!, remnant, valid_to, old_to)
            elsif left
              model.send(:guarded_validity_update!, row, to_col=>valid_from)
            elsif right
              model.send(:guarded_validity_update!, row, from_col=>valid_to)
            else
              model.send(:guarded_validity_delete!, row)
            end
          end
          model.send(:insert_validity_version!, attributes, valid_from, valid_to, key)
        end
      end

      module ClassMethods
        attr_accessor :validity_versions_opts

        Plugins.inherited_instance_variables(self, :@validity_versions_opts=>nil)

        # The column holding the logical key shared by all versions of a
        # record.
        def validity_key_column
          validity_versions_opts[:key]
        end

        # The column holding the inclusive start of each version's valid
        # interval.
        def validity_from_column
          validity_versions_opts[:from]
        end

        # The column holding the exclusive end of each version's valid
        # interval.  NULL represents infinity.
        def validity_to_column
          validity_versions_opts[:to]
        end

        # The integer column used for optimistic concurrency control.
        def validity_lock_column
          validity_versions_opts[:lock_column]
        end

        # Whether adjacent versions with identical content are merged.
        def validity_merge_adjacent?
          validity_versions_opts[:merge_adjacent]
        end

        # Dataset of all versions for the given logical key, ordered by
        # valid_from.
        def versions_of(key)
          where(validity_key_column=>key).order(validity_from_column)
        end

        # The version of the given logical key valid at the given time,
        # or nil if no version covers the time.
        def as_of(key, time)
          versions_of(key).validity_at(time).first
        end

        # Create a single version for the logical key over
        # [valid_from, valid_to).  Raises InvalidInterval for empty or
        # inverted intervals and OverlappingVersions if the interval
        # overlaps existing history.
        def create_version(key, valid_from, valid_to, attributes={})
          check_revision_attributes!(attributes)
          db.transaction do
            version = insert_validity_version!(attributes, valid_from, valid_to, key)
            merge_validity_neighbors!(version) if validity_merge_adjacent?
            version
          end
        end

        # Revise the attributes of the logical key over
        # [valid_from, valid_to), splitting covered versions so the parts
        # outside the interval keep their old values.  The whole revision
        # commits atomically.  Returns the new version.
        def revise(key, valid_from, valid_to, attributes={})
          plan_revision(key, valid_from, valid_to, attributes).commit
        end

        # Plan a revision without applying it.  The returned Revision
        # captures the currently covered versions; committing it later
        # raises ValidityVersions::Conflict if another revision has
        # modified those versions in the meantime.
        def plan_revision(key, valid_from, valid_to, attributes={})
          Revision.new(self, key, valid_from, valid_to, attributes)
        end

        private

        # Columns compared when deciding whether adjacent versions have
        # identical content.
        def validity_content_columns
          excluded = [primary_key, validity_key_column, validity_from_column,
                      validity_to_column, validity_lock_column]
          columns - excluded
        end

        def validate_validity_interval!(valid_from, valid_to)
          if valid_from.nil?
            raise InvalidInterval, "valid_from is required (valid_to of nil means infinity)"
          elsif valid_to && valid_to <= valid_from
            raise InvalidInterval, "empty or inverted validity interval: [#{valid_from}, #{valid_to})"
          end
        end

        def check_revision_attributes!(attributes)
          reserved = [primary_key, validity_key_column, validity_from_column,
                      validity_to_column, validity_lock_column]
          if (bad = attributes.keys & reserved).any?
            raise Error, "revision attributes cannot include #{bad.join(', ')}"
          end
        end

        def validate_no_validity_overlap!(record)
          key = record.get_column_value(validity_key_column)
          ds = versions_of(key).validity_overlapping(
            record.get_column_value(validity_from_column),
            record.get_column_value(validity_to_column))
          ds = ds.exclude(primary_key=>record.pk) unless record.new?
          unless ds.empty?
            raise OverlappingVersions, "version overlaps existing history for key #{key.inspect}"
          end
        end

        def insert_validity_version!(attributes, valid_from, valid_to, key=nil)
          values = attributes.dup
          values[validity_key_column] = key unless key.nil?
          values[validity_from_column] = valid_from
          values[validity_to_column] = valid_to
          values[validity_lock_column] = 0
          create(values)
        end

        # Attributes for a remnant of +row+ that keeps the row's content
        # and logical key but gets fresh interval bounds and lock version.
        def validity_remnant_attributes(row)
          reserved = [primary_key, validity_from_column, validity_to_column, validity_lock_column]
          row.values.reject{|col, _| reserved.include?(col)}
        end

        def guarded_validity_update!(row, changes)
          lock = validity_lock_column
          current = row.get_column_value(lock)
          n = where(primary_key=>row.pk, lock=>current).update(changes.merge(lock=>current + 1))
          unless n == 1
            raise Conflict, "version #{row.pk.inspect} of key #{row.get_column_value(validity_key_column).inspect} was modified concurrently"
          end
        end

        def guarded_validity_delete!(row)
          lock = validity_lock_column
          n = where(primary_key=>row.pk, lock=>row.get_column_value(lock)).delete
          unless n == 1
            raise Conflict, "version #{row.pk.inspect} of key #{row.get_column_value(validity_key_column).inspect} was modified concurrently"
          end
        end

        # Merge +version+ with an adjacent previous and/or next version
        # that has identical content, extending the version's interval.
        def merge_validity_neighbors!(version)
          from_col = validity_from_column
          to_col = validity_to_column
          key = version.get_column_value(validity_key_column)
          content = validity_content_columns
          same_content = lambda do |other|
            content.all?{|c| other.get_column_value(c) == version.get_column_value(c)}
          end

          ds = versions_of(key)
          if (left = ds.first(to_col=>version.get_column_value(from_col))) && same_content.call(left)
            guarded_validity_delete!(left)
            version.set_column_value("#{from_col}=", left.get_column_value(from_col))
            version.save
          end

          valid_to = version.get_column_value(to_col)
          if valid_to && (right = ds.first(from_col=>valid_to)) && same_content.call(right)
            guarded_validity_delete!(right)
            version.set_column_value("#{to_col}=", right.get_column_value(to_col))
            version.save
          end
          version
        end
      end

      module InstanceMethods
        def before_save
          super
          model.send(:validate_validity_interval!,
                     get_column_value(model.validity_from_column),
                     get_column_value(model.validity_to_column))
          model.send(:validate_no_validity_overlap!, self)
        end
      end

      module DatasetMethods
        # Versions valid at the given time: valid_from <= time and
        # (valid_to IS NULL or valid_to > time).
        def validity_at(time)
          from = model.validity_from_column
          to = model.validity_to_column
          where(Sequel.expr(from) <= time).
            where(Sequel.|({to=>nil}, Sequel.expr(to) > time))
        end

        # Versions whose interval overlaps [from_time, to_time).  A nil
        # to_time means infinity.
        def validity_overlapping(from_time, to_time)
          from = model.validity_from_column
          to = model.validity_to_column
          ds = where(Sequel.|({to=>nil}, Sequel.expr(to) > from_time))
          ds = ds.where(Sequel.expr(from) < to_time) if to_time
          ds
        end
      end
    end
  end
end
