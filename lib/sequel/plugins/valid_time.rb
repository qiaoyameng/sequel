# frozen-string-literal: true

module Sequel
  module Plugins
    # The valid_time plugin adds business-time (valid-time) versioning to a
    # model.  Each logical key (identified by a key column) can have multiple
    # version rows, each valid for a half-open interval
    # [valid_from, valid_to).  A +nil+ valid_to represents infinity.
    #
    # The timestamps managed by this plugin are business times supplied by
    # the caller; the plugin never substitutes the database update time for
    # them.
    #
    # Usage:
    #
    #   class Product < Sequel::Model
    #     plugin :valid_time, key: :sku
    #   end
    #
    #   # Store three versions for the same logical key
    #   Product.create_version('A', t0, t1, name: 'v1')
    #   Product.create_version('A', t1, t2, name: 'v2')
    #   Product.create_version('A', t2, nil, name: 'v3') # open ended
    #
    #   # Query the version valid at a given business time
    #   Product.as_of('A', t1) # => version with name 'v2'
    #
    #   # Revise attributes over a time range.  Existing versions covered by
    #   # the range are split, and the old attribute values are preserved on
    #   # both sides of the revised range:
    #   Product.revise('A', t05, t25, name: 'new')
    #
    # The table used by the model must have columns for the logical key
    # (default +:key+, set with the +:key+ option), +valid_from+,
    # +valid_to+, and an integer +lock_version+ column defaulting to 0 used
    # for optimistic concurrency control.  Column names can be changed with
    # the +:valid_from+, +:valid_to+, and +:lock_column+ options.
    #
    # By default, adjacent versions with identical content are kept as
    # separate rows.  Pass <tt>merge_adjacent: true</tt> to merge adjacent
    # versions whose content is identical into a single version.
    #
    # Empty intervals (valid_from == valid_to), inverted intervals
    # (valid_from > valid_to), and inserting a version that overlaps
    # existing history are rejected.  A revision that spans multiple
    # versions is performed in a single transaction, so a failure leaves all
    # original intervals untouched.  Concurrent revisions of the same
    # logical key are detected using the lock column and raise
    # Sequel::Plugins::ValidTime::ConflictError instead of silently
    # overwriting.
    module ValidTime
      # Base error class for the valid_time plugin.
      Error = Class.new(Sequel::Error)

      # Raised when an empty or inverted valid-time interval is given.
      InvalidInterval = Class.new(Error)

      # Raised when inserting a version that would overlap existing history.
      OverlappingHistory = Class.new(Error)

      # Raised when a concurrent modification of the same logical key is
      # detected during a revision.
      ConflictError = Class.new(Error)

      def self.configure(model, opts=OPTS)
        model.valid_time_key_column = (opts[:key] || :key).to_sym
        model.valid_time_from_column = (opts[:valid_from] || :valid_from).to_sym
        model.valid_time_to_column = (opts[:valid_to] || :valid_to).to_sym
        model.valid_time_lock_column = (opts[:lock_column] || :lock_version).to_sym
        model.valid_time_merge_adjacent = opts[:merge_adjacent] ? true : false
      end

      module ClassMethods
        # Column identifying the logical key shared by all versions.
        attr_accessor :valid_time_key_column

        # Column holding the inclusive start of the valid-time interval.
        attr_accessor :valid_time_from_column

        # Column holding the exclusive end of the valid-time interval
        # (+nil+ means infinity).
        attr_accessor :valid_time_to_column

        # Integer column used for optimistic concurrency control.
        attr_accessor :valid_time_lock_column

        # Whether adjacent versions with identical content are merged.
        attr_accessor :valid_time_merge_adjacent

        # Copy plugin settings to subclasses.
        def inherited(subclass)
          super
          subclass.valid_time_key_column = valid_time_key_column
          subclass.valid_time_from_column = valid_time_from_column
          subclass.valid_time_to_column = valid_time_to_column
          subclass.valid_time_lock_column = valid_time_lock_column
          subclass.valid_time_merge_adjacent = valid_time_merge_adjacent
        end

        # Return the version of the given logical key valid at the given
        # business time, or nil if no version covers that time.
        def as_of(key, time)
          valid_time_key_dataset(key).valid_time_as_of(time).
            order(valid_time_from_column).last
        end

        # Dataset of all versions for the given logical key, ordered by
        # valid_from.
        def history(key)
          valid_time_key_dataset(key).order(valid_time_from_column)
        end

        # Insert a new version for the given logical key covering
        # [from, to).  Raises InvalidInterval for empty or inverted
        # intervals, and OverlappingHistory if the interval overlaps any
        # existing version of the same logical key.
        def create_version(key, from, to, attrs=OPTS)
          valid_time_validate_interval!(from, to)
          db.transaction do
            unless valid_time_key_dataset(key).valid_time_overlapping(from, to).empty?
              raise OverlappingHistory, "valid-time interval [#{from}, #{to}) overlaps existing history for key #{key.inspect}"
            end
            create(attrs.merge(valid_time_key_column=>key,
                               valid_time_from_column=>from,
                               valid_time_to_column=>to,
                               valid_time_lock_column=>0))
          end
        end

        # Revise the attributes of the given logical key over [from, to).
        # Existing versions overlapping the range are split: the parts
        # outside the range keep their old attribute values, the parts
        # inside the range are replaced by a single new version with the
        # given attributes.  The whole revision runs in one transaction, so
        # a failure preserves all original intervals.
        #
        # The versions overlapping the range are read before the write
        # transaction starts, and each version is only removed if its lock
        # version is unchanged.  If another transaction modified the same
        # logical key concurrently, ConflictError is raised instead of
        # silently overwriting the other transaction's changes.  The
        # The +:base+ option can be used to pass an explicit array of
        # previously loaded versions to check against.
        def revise(key, from, to, attrs, opts=OPTS)
          valid_time_validate_interval!(from, to)
          from_column = valid_time_from_column
          to_column = valid_time_to_column
          rows = opts[:base] || valid_time_key_dataset(key).
            valid_time_overlapping(from, to).
            order(from_column).all
          db.transaction do
            rows.each{|row| row.send(:valid_time_lock_delete!)}
            rows.each do |row|
              content = row.valid_time_content
              if row[from_column] < from
                valid_time_insert(content, key, row[from_column], from)
              end
              if to && (row[to_column].nil? || row[to_column] > to)
                valid_time_insert(content, key, to, row[to_column])
              end
            end
            valid_time_insert(attrs, key, from, to)
            valid_time_merge_adjacent!(key) if valid_time_merge_adjacent
            nil
          end
        end

        # Dataset of all versions for the given logical key.
        def valid_time_key_dataset(key)
          where(valid_time_key_column=>key)
        end

        private

        def valid_time_validate_interval!(from, to)
          if from.nil?
            raise InvalidInterval, "valid_from must not be nil"
          end
          if to && to <= from
            raise InvalidInterval, "invalid valid-time interval [#{from}, #{to}): empty or inverted intervals are not allowed"
          end
        end

        def valid_time_insert(content, key, from, to)
          dataset.insert(content.merge(valid_time_key_column=>key,
                                       valid_time_from_column=>from,
                                       valid_time_to_column=>to,
                                       valid_time_lock_column=>0))
        end

        def valid_time_merge_adjacent!(key)
          from_column = valid_time_from_column
          to_column = valid_time_to_column
          loop do
            rows = valid_time_key_dataset(key).order(from_column).all
            merged = false
            rows.each_cons(2) do |a, b|
              if a[to_column] == b[from_column] && a.valid_time_content == b.valid_time_content
                content = a.valid_time_content
                a.send(:valid_time_lock_delete!)
                b.send(:valid_time_lock_delete!)
                valid_time_insert(content, key, a[from_column], b[to_column])
                merged = true
                break
              end
            end
            break unless merged
          end
        end
      end

      module DatasetMethods
        # Dataset of versions valid at the given business time:
        # valid_from <= time AND (valid_to IS NULL OR valid_to > time).
        def valid_time_as_of(time)
          from_column = model.valid_time_from_column
          to_column = model.valid_time_to_column
          where(Sequel[from_column] <= time).
            where(Sequel.|({to_column=>nil}, Sequel[to_column] > time))
        end

        # Dataset of versions whose interval overlaps [from, to).
        # A nil +to+ means the interval extends to infinity.
        def valid_time_overlapping(from, to)
          from_column = model.valid_time_from_column
          to_column = model.valid_time_to_column
          ds = where(Sequel.|({to_column=>nil}, Sequel[to_column] > from))
          to ? ds.where(Sequel[from_column] < to) : ds
        end
      end

      module InstanceMethods
        # Hash of the business attribute values of this version, excluding
        # the primary key, logical key, valid-time interval, and lock
        # columns.
        def valid_time_content
          excluded = [model.valid_time_key_column,
                      model.valid_time_from_column,
                      model.valid_time_to_column,
                      model.valid_time_lock_column]
          excluded.concat(Array(model.primary_key))
          values.reject{|column, _| excluded.include?(column)}
        end

        private

        # Delete this version's row, but only if its lock version is
        # unchanged.  Raises ConflictError if a concurrent transaction
        # modified or deleted the row.
        def valid_time_lock_delete!
          lock_column = model.valid_time_lock_column
          deleted = this.where(lock_column=>get_column_value(lock_column)).delete
          unless deleted == 1
            raise ConflictError, "concurrent modification detected while revising #{model.name} #{pk.inspect}"
          end
        end
      end
    end
  end
end
