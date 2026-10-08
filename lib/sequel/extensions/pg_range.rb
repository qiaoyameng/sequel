# frozen-string-literal: true
#
# The pg_range extension adds support for the PostgreSQL 9.2+ range
# types to Sequel.  PostgreSQL range types are similar to ruby's
# Range class, representing an array of values.  However, they
# are more flexible than ruby's ranges, allowing exclusive beginnings
# and endings (ruby's range only allows exclusive endings).
#
# When PostgreSQL range values are retrieved, they are parsed and returned
# as instances of Sequel::Postgres::PGRange.  PGRange mostly acts
# like a Range, but it's not a Range as not all PostgreSQL range
# type values would be valid ruby ranges.  If the range type value
# you are using is a valid ruby range, you can call PGRange#to_range
# to get a Range.  However, if you call PGRange#to_range on a range
# type value uses features that ruby's Range does not support, an
# exception will be raised.
#
# In addition to the parser, this extension comes with literalizers
# for PGRange and Range, so they can be used in queries and as bound variables.
#
# This extension also supports computing unions, intersections, and
# differences of ranges locally, without a database connection:
#
#   r1.union(r2)         # => PGMultiRange
#   r1.intersection(r2)  # => PGMultiRange
#   r1.difference(r2)    # => PGMultiRange
#
# These methods are also available on PGMultiRange instances, accept
# PGRange, PGMultiRange, and Range instances as arguments, and return
# normalized PGMultiRange instances (from the pg_multirange extension,
# which must be loaded) containing sorted, non-overlapping ranges.
# Ranges over discrete domains (such as integers and dates) are
# normalized to PostgreSQL's canonical [) form using a successor
# function.  The successor function is chosen automatically for
# Integer and Date endpoints, and can be provided explicitly for
# other discrete domains via the :successor option:
#
#   r1.union(r2, :successor=>lambda{|v| v + 1})
#
# To turn an existing Range into a PGRange, use Sequel.pg_range:
#
#   Sequel.pg_range(range)
#
# If you have loaded the {core_extensions extension}[rdoc-ref:doc/core_extensions.rdoc],
# or you have loaded the core_refinements extension
# and have activated refinements for the file, you can also use Range#pg_range:
#
#   range.pg_range 
#
# You may want to specify a specific range type:
#
#   Sequel.pg_range(range, :daterange)
#   range.pg_range(:daterange)
#
# If you specify the range database type, Sequel will automatically cast
# the value to that type when literalizing.
#
# To use this extension, load it into the Database instance:
#
#   DB.extension :pg_range
#
# See the {schema modification guide}[rdoc-ref:doc/schema_modification.rdoc]
# for details on using range type columns in CREATE/ALTER TABLE statements.
#
# This extension makes it easy to add support for other range types.  In
# general, you just need to make sure that the subtype is handled and has the
# appropriate converter installed.  For user defined
# types, you can do this via:
#
#   DB.add_conversion_proc(subtype_oid){|string| }
#
# Then you can call
# Sequel::Postgres::PGRange::DatabaseMethods#register_range_type
# to automatically set up a handler for the range type.  So if you
# want to support the timerange type (assuming the time type is already
# supported):
#
#   DB.register_range_type('timerange')
#
# This extension integrates with the pg_array extension.  If you plan
# to use arrays of range types, load the pg_array extension before the
# pg_range extension:
#
#   DB.extension :pg_array, :pg_range
#
# Related module: Sequel::Postgres::PGRange

module Sequel
  module Postgres
    class PGRange
      include Sequel::SQL::AliasMethods

      # Creates callable objects that convert strings into PGRange instances.
      class Parser
        # The database range type for this parser (e.g. 'int4range'),
        # automatically setting the db_type for the returned PGRange instances.
        attr_reader :db_type

        # A callable object to convert the beginning and ending of the range into
        # the appropriate ruby type.
        attr_reader :converter

        # Set the db_type and converter on initialization.
        def initialize(db_type, converter=nil)
          @db_type = db_type.to_s.dup.freeze if db_type
          @converter = converter
        end

        # Parse the range type input string into a PGRange value.
        def call(string)
          if string == 'empty'
            return PGRange.empty(db_type)
          end

          raise(InvalidValue, "invalid or unhandled range format: #{string.inspect}") unless matches = /\A(\[|\()("((?:\\"|[^"])*)"|[^"]*),("((?:\\"|[^"])*)"|[^"]*)(\]|\))\z/.match(string)

          exclude_begin = matches[1] == '('
          exclude_end = matches[6] == ')'

          # If the input is quoted, it needs to be unescaped.  Also, quoted input isn't
          # checked for emptiness, since the empty quoted string is considered an 
          # element that happens to be the empty string, while an unquoted empty string
          # is considered unbounded.
          #
          # While PostgreSQL allows pure escaping for input (without quoting), it appears
          # to always use the quoted output form when characters need to be escaped, so
          # there isn't a need to unescape unquoted output.
          if beg = matches[3]
            beg.gsub!(/\\(.)/, '\1')
          else
            beg = matches[2] unless matches[2].empty?
          end
          if en = matches[5]
            en.gsub!(/\\(.)/, '\1')
          else
            en = matches[4] unless matches[4].empty?
          end

          if c = converter
            beg = c.call(beg) if beg
            en = c.call(en) if en
          end

          PGRange.new(beg, en, :exclude_begin=>exclude_begin, :exclude_end=>exclude_end, :db_type=>db_type)
        end
      end

      module DatabaseMethods
        # Add the conversion procs to the database
        # and extend the datasets to correctly literalize ruby Range values.
        def self.extended(db)
          db.instance_exec do
            @pg_range_schema_types ||= {}
            extend_datasets(DatasetMethods)
            register_range_type('int4range', :oid=>3904, :subtype_oid=>23)
            register_range_type('numrange', :oid=>3906, :subtype_oid=>1700)
            register_range_type('tsrange', :oid=>3908, :subtype_oid=>1114)
            register_range_type('tstzrange', :oid=>3910, :subtype_oid=>1184)
            register_range_type('daterange', :oid=>3912, :subtype_oid=>1082)
            register_range_type('int8range', :oid=>3926, :subtype_oid=>20)
            if respond_to?(:register_array_type)
              register_array_type('int4range', :oid=>3905, :scalar_oid=>3904, :scalar_typecast=>:int4range)
              register_array_type('numrange', :oid=>3907, :scalar_oid=>3906, :scalar_typecast=>:numrange)
              register_array_type('tsrange', :oid=>3909, :scalar_oid=>3908, :scalar_typecast=>:tsrange)
              register_array_type('tstzrange', :oid=>3911, :scalar_oid=>3910, :scalar_typecast=>:tstzrange)
              register_array_type('daterange', :oid=>3913, :scalar_oid=>3912, :scalar_typecast=>:daterange)
              register_array_type('int8range', :oid=>3927, :scalar_oid=>3926, :scalar_typecast=>:int8range)
            end
            [:int4range, :numrange, :tsrange, :tstzrange, :daterange, :int8range].each do |v|
              @schema_type_classes[v] = PGRange
            end

            procs = conversion_procs
            add_conversion_proc(3908, Parser.new("tsrange", procs[1114]))
            add_conversion_proc(3910, Parser.new("tstzrange", procs[1184]))
            if respond_to?(:register_array_type) && defined?(PGArray::Creator)
              add_conversion_proc(3909, PGArray::Creator.new("tsrange", procs[3908]))
              add_conversion_proc(3911, PGArray::Creator.new("tstzrange", procs[3910]))
            end
          end
        end

        # Handle Range and PGRange values in bound variables
        def bound_variable_arg(arg, conn)
          case arg
          when PGRange 
            arg.unquoted_literal(schema_utility_dataset)
          when Range
            PGRange.from_range(arg).unquoted_literal(schema_utility_dataset)
          else
            super
          end
        end

        # Freeze the pg range schema types to prevent adding new ones.
        def freeze
          @pg_range_schema_types.freeze
          super
        end

        # Register a database specific range type.  This can be used to support
        # different range types per Database.  Options:
        #
        # :converter :: A callable object (e.g. Proc), that is called with the start or end of the range
        #               (usually a string), and should return the appropriate typecasted object.
        # :oid :: The PostgreSQL OID for the range type.  This is used by the Sequel postgres adapter
        #         to set up automatic type conversion on retrieval from the database.
        # :subtype_oid :: Should be the PostgreSQL OID for the range's subtype. If given,
        #                 automatically sets the :converter option by looking for scalar conversion
        #                 proc.
        #
        # If a block is given, it is treated as the :converter option.
        def register_range_type(db_type, opts=OPTS, &block)
          oid = opts[:oid]
          soid = opts[:subtype_oid]

          if has_converter = opts.has_key?(:converter)
            raise Error, "can't provide both a block and :converter option to register_range_type" if block
            converter = opts[:converter]
          else
            has_converter = true if block
            converter = block
          end

          unless (soid || has_converter) && oid
            range_oid, subtype_oid = from(:pg_range).join(:pg_type, :oid=>:rngtypid).where(:typname=>db_type.to_s).get([:rngtypid, :rngsubtype])
            soid ||= subtype_oid unless has_converter
            oid ||= range_oid
          end

          db_type = db_type.to_s.dup.freeze

          if soid
            raise Error, "can't provide both a converter and :subtype_oid option to register" if has_converter 
            raise Error, "no conversion proc for :subtype_oid=>#{soid.inspect} in conversion_procs" unless converter = conversion_procs[soid]
          end

          parser = Parser.new(db_type, converter)
          add_conversion_proc(oid, parser)

          @pg_range_schema_types[db_type] = db_type.to_sym

          singleton_class.class_eval do
            meth = :"typecast_value_#{db_type}"
            define_method(meth){|v| typecast_value_pg_range(v, parser)}
            private meth
          end

          @schema_type_classes[:"#{opts[:type_symbol] || db_type}"] = PGRange
          nil
        end

        private

        # Recognize the registered database range types.
        def schema_range_type(db_type)
          @pg_range_schema_types[db_type] || super
        end

        # Set the :ruby_default value if the default value is recognized as a range.
        def schema_post_process(_)
          super.each do |a|
            h = a[1]
            db_type = h[:db_type]
            if @pg_range_schema_types[db_type] && h[:default] =~ /\A'([^']+)'::#{db_type}\z/
              default = $1
              if convertor = conversion_procs[h[:oid]]
                h[:ruby_default] = convertor.call(default)
              end
            end
          end
        end

        # Typecast value correctly to a PGRange.  If already an
        # PGRange instance with the same db_type, return as is.
        # If a PGRange with a different subtype, return a new
        # PGRange with the same values and the expected subtype.
        # If a Range object, create a PGRange with the given
        # db_type.  If a string, assume it is in PostgreSQL
        # output format and parse it using the parser.
        def typecast_value_pg_range(value, parser)
          case value
          when PGRange
            if value.db_type.to_s == parser.db_type
              value
            elsif value.empty?
              PGRange.empty(parser.db_type)
            else
              PGRange.new(value.begin, value.end, :exclude_begin=>value.exclude_begin?, :exclude_end=>value.exclude_end?, :db_type=>parser.db_type)
            end
          when Range
            PGRange.from_range(value, parser.db_type)
          when String
            parser.call(typecast_check_string_length(value, 100))
          else
            raise Sequel::InvalidValue, "invalid value for range type: #{value.inspect}"
          end
        end
      end

      module DatasetMethods
        private

        # Handle literalization of ruby Range objects, treating them as
        # PostgreSQL ranges.
        def literal_other_append(sql, v)
          case v
          when Range
            super(sql, Sequel::Postgres::PGRange.from_range(v))
          else
            super
          end
        end
      end

      include Enumerable

      # The beginning of the range.  If nil, the range has an unbounded beginning.
      attr_reader :begin

      # The end of the range.  If nil, the range has an unbounded ending.
      attr_reader :end

      # The PostgreSQL database type for the range (e.g. 'int4range').
      attr_reader :db_type

      # Create a new PGRange instance using the beginning and ending of the ruby Range,
      # with the given db_type.
      def self.from_range(range, db_type=nil)
        new(range.begin, range.end, :exclude_end=>range.exclude_end?, :db_type=>db_type)
      end

      # Create an empty PGRange with the given database type.
      def self.empty(db_type=nil)
        new(nil, nil, :empty=>true, :db_type=>db_type)
      end

      # Initialize a new PGRange instance.  Accepts the following options:
      #
      # :db_type :: The PostgreSQL database type for the range.
      # :empty :: Whether the range is empty (has no points)
      # :exclude_begin :: Whether the beginning element is excluded from the range.
      # :exclude_end :: Whether the ending element is excluded from the range.
      def initialize(beg, en, opts=OPTS)
        @begin = beg
        @end = en
        @empty = !!opts[:empty]
        @exclude_begin = !!opts[:exclude_begin]
        @exclude_end = !!opts[:exclude_end]
        @db_type = opts[:db_type]
        if @empty
          raise(Error, 'cannot have an empty range with either a beginning or ending') unless @begin.nil? && @end.nil? && opts[:exclude_begin].nil? && opts[:exclude_end].nil?
        end
      end

      # Delegate to the ruby range object so that the object mostly acts like a range.
      range_methods = %w'each last first step'
      range_methods.each do |m|
        class_eval("def #{m}(*a, &block) to_range.#{m}(*a, &block) end", __FILE__, __LINE__)
      end

      # Return whether the value is inside the range.
      def cover?(value)
        return false if empty?
        b = self.begin
        return false if b && b.public_send(exclude_begin? ? :>= : :>, value)
        e = self.end
        return false if e && e.public_send(exclude_end? ? :<= : :<, value)
        true
      end

      # Return the union of this range and the given range or multirange,
      # as a normalized PGMultiRange (sorted, non-overlapping ranges).
      # Requires the pg_multirange extension.  See SetOps.compute for
      # supported options.
      def union(other, opts=OPTS)
        set_operation(:union, other, opts)
      end

      # Return the intersection of this range and the given range or
      # multirange, as a normalized PGMultiRange (sorted, non-overlapping
      # ranges).  Requires the pg_multirange extension.  See SetOps.compute
      # for supported options.
      def intersection(other, opts=OPTS)
        set_operation(:intersection, other, opts)
      end

      # Return the difference of this range and the given range or
      # multirange, as a normalized PGMultiRange (sorted, non-overlapping
      # ranges).  Requires the pg_multirange extension.  See SetOps.compute
      # for supported options.
      def difference(other, opts=OPTS)
        set_operation(:difference, other, opts)
      end

      # Consider the receiver equal to other PGRange instances with the
      # same beginning, ending, exclusions, and database type.  Also consider
      # it equal to Range instances if this PGRange can be converted to a
      # a Range and those ranges are equal.
      def eql?(other)
        case other
        when PGRange
          if db_type == other.db_type
            if empty?
              other.empty?
            elsif other.empty?
              false
            else
              [:@begin, :@end, :@exclude_begin, :@exclude_end].all?{|v| instance_variable_get(v) == other.instance_variable_get(v)}
            end
          else
            false
          end
        when Range
          if valid_ruby_range?
            to_range.eql?(other)
          else
            false
          end
        else
          false
        end
      end
      alias == eql?

      # Make sure equal ranges have the same hash.
      def hash
        if @empty
          @db_type.hash
        else
          [@begin, @end, @exclude_begin, @exclude_end, @db_type].hash
        end
      end

      # Allow PGRange values in case statements, where they return true if they
      # are equal to each other using eql?, or if this PGRange can be converted
      # to a Range, delegating to that range.
      def ===(other)
        if eql?(other)
          true
        else
          if valid_ruby_range?
            to_range === other 
          else
            false
          end
        end
      end

      # Whether this range is empty (has no points).  Note that for manually created ranges
      # (ones not retrieved from the database), this will only be true if the range
      # was created using the :empty option.
      def empty?
        @empty
      end

      # Whether the beginning element is excluded from the range.
      def exclude_begin?
        @exclude_begin
      end

      # Whether the ending element is excluded from the range.
      def exclude_end?
        @exclude_end
      end

      # Support a friendly output
      def inspect
        range = if empty?
          "empty"
        else
          "#{@exclude_begin ? "(" : "["}#{@begin},#{@end}#{@exclude_end ? ")" : "]"}"
        end

        "#<#{self.class.name} #{range}#{"::#{@db_type}" if @db_type}>"
      end
      alias to_s inspect

      # Append a literalize version of the receiver to the sql.
      def sql_literal_append(ds, sql)
        if (s = @db_type) && !empty?
          sql << s.to_s << "("
          ds.literal_append(sql, self.begin)
          sql << ','
          ds.literal_append(sql, self.end)
          sql << ','
          ds.literal_append(sql, "#{exclude_begin? ? "(" : "["}#{exclude_end? ? ")" : "]"}")
          sql << ")"
        else
          ds.literal_append(sql, unquoted_literal(ds))
          if s
            sql << '::' << s.to_s
          end
        end
      end

      ENDLESS_RANGE_NOT_SUPPORTED = RUBY_VERSION < '2.6'
      STARTLESS_RANGE_NOT_SUPPORTED = RUBY_VERSION < '2.7'

      # Return a ruby Range object for this instance, if one can be created.
      def to_range
        return @range if @range
        raise(Error, "cannot create ruby range for an empty PostgreSQL range") if empty?
        raise(Error, "cannot create ruby range when PostgreSQL range excludes beginning element") if exclude_begin?
        # simplecov:disable
        raise(Error, "cannot create ruby range when PostgreSQL range has unbounded beginning") if STARTLESS_RANGE_NOT_SUPPORTED && !self.begin
        raise(Error, "cannot create ruby range when PostgreSQL range has unbounded ending") if ENDLESS_RANGE_NOT_SUPPORTED && !self.end
        # simplecov:enable
        @range = Range.new(self.begin, self.end, exclude_end?)
      end

      # Whether or not this PGRange is a valid ruby range.  In order to be a valid ruby range,
      # it must have a beginning and an ending (no unbounded ranges), and it cannot exclude
      # the beginning element.
      def valid_ruby_range?
        !(empty? || exclude_begin? || (STARTLESS_RANGE_NOT_SUPPORTED && !self.begin) || (ENDLESS_RANGE_NOT_SUPPORTED && !self.end))
      end

      # Whether the beginning of the range is unbounded.
      def unbounded_begin?
        self.begin.nil? && !empty?
      end

      # Whether the end of the range is unbounded.
      def unbounded_end?
        self.end.nil? && !empty?
      end

      # Return a string containing the unescaped version of the range.
      # Separated out for use by the bound argument code.
      def unquoted_literal(ds)
        if empty?
          'empty'
        else
          "#{exclude_begin? ? "(" : "["}#{escape_value(self.begin, ds)},#{escape_value(self.end, ds)}#{exclude_end? ? ")" : "]"}"
        end
      end

      # Allow automatic parameterization for ranges with types, if both start .
      def sequel_auto_param_type(ds)
        "::#{db_type}" if db_type && (!@begin || ds.send(:auto_param_type, @begin)) && (!@end || ds.send(:auto_param_type, @end))
      end

      private

      # Compute a set operation between this range and the given object,
      # returning a normalized PGMultiRange.  Requires the pg_multirange
      # extension, since the result is a PGMultiRange.
      def set_operation(op, other, opts)
        unless defined?(Sequel::Postgres::PGMultiRange)
          raise Sequel::Error, "load the pg_multirange extension to compute range set operations"
        end
        SetOps.compute(op, self, other, opts)
      end

      # Escape common range types.  Instead of quoting, just backslash escape all
      # special characters.
      def escape_value(k, ds)
        case k
        when nil
          ''
        when Time, Date
          ds.literal_date_or_time(k, true)
        when Integer, Float
          k.to_s
        when BigDecimal
          k.to_s('F')
        when LiteralString
          k
        when String
          if k.empty?
            '""'
          else
            k.gsub(/("|,|\\|\[|\]|\(|\))/, '\\\\\1')
          end
        else
          ds.literal(k).gsub(/("|,|\\|\[|\]|\(|\))/, '\\\\\1')
        end
      end
    end

    # SetOps implements offline set operations (union, intersection, and
    # difference) on PGRange and PGMultiRange instances, without requiring
    # a database connection.  All operations return normalized PGMultiRange
    # instances (sorted, non-overlapping ranges), and do not modify their
    # arguments.
    #
    # Internally, ranges are converted to intervals of the form
    # [lower, lower_inclusive, upper, upper_inclusive], where a nil lower
    # or upper represents an unbounded endpoint.  Ranges over discrete
    # domains are first normalized to half-open [) intervals using a
    # successor function, mirroring PostgreSQL's canonical form for
    # discrete range types.
    module PGRange::SetOps
      # Successor functions used to normalize ranges over discrete domains
      # to half-open intervals, by endpoint class.  Continuous domains
      # (e.g. Float, BigDecimal, Time) have no successor and are handled
      # using their inclusive/exclusive bounds directly.
      DISCRETE_SUCCESSORS = {
        Integer => lambda{|v| v + 1},
        Date => lambda{|v| v + 1}
      }.freeze

      module_function

      # Compute the given set operation (:union, :intersection, or
      # :difference) between two PGRange/PGMultiRange/Range values,
      # returning a normalized PGMultiRange.  Raises Sequel::Error if the
      # database types of the arguments differ, or if their endpoints
      # cannot be compared.  Options:
      #
      # :successor :: A callable returning the successor of a range
      #               endpoint, used to normalize ranges over discrete
      #               domains to PostgreSQL's canonical [) form.  By
      #               default, Integer and Date endpoints use a successor
      #               of +1, and other endpoints are treated as
      #               continuous.
      def compute(op, left, right, opts=OPTS)
        left_ranges, left_type = ranges_and_type(left)
        right_ranges, right_type = ranges_and_type(right)
        db_type = compatible_db_type(left_type, right_type)
        successor = discrete_successor(left_ranges, right_ranges, opts)

        left_intervals = normalize_ranges(left_ranges, successor)
        right_intervals = normalize_ranges(right_ranges, successor)

        intervals = case op
        when :union
          merge_intervals(left_intervals + right_intervals)
        when :intersection
          intersect_intervals(left_intervals, right_intervals)
        when :difference
          difference_intervals(left_intervals, right_intervals)
        else
          raise Sequel::Error, "unsupported range set operation: #{op.inspect}"
        end

        build_multirange(intervals, db_type, successor)
      end

      # Extract an array of PGRange instances and the common database
      # range type from the given object.
      def ranges_and_type(obj)
        case obj
        when PGRange
          [[obj], normalize_db_type(obj.db_type)]
        when Range
          [[PGRange.from_range(obj)], nil]
        when PGMultiRange
          ranges = obj.map{|r| to_pg_range(r)}
          [ranges, uniform_db_type(ranges) || range_type_for_multirange(obj.db_type)]
        when Array
          ranges = obj.map{|r| to_pg_range(r)}
          [ranges, uniform_db_type(ranges)]
        else
          raise Sequel::Error, "invalid argument for range set operation: #{obj.inspect}"
        end
      end

      # Convert the object to a PGRange, raising for invalid objects.
      def to_pg_range(obj)
        case obj
        when PGRange
          obj
        when Range
          PGRange.from_range(obj)
        else
          raise Sequel::Error, "invalid range in range set operation: #{obj.inspect}"
        end
      end

      # Return the database range type shared by all given ranges,
      # raising if the ranges use different database types.
      def uniform_db_type(ranges)
        types = ranges.map{|r| normalize_db_type(r.db_type)}.compact.uniq
        if types.length > 1
          raise Sequel::Error, "cannot compute set operations on ranges with different database types: #{types.join(' and ')}"
        end
        types.first
      end

      # Normalize a database type to a string, treating nil and empty
      # types as untyped.
      def normalize_db_type(type)
        if type
          type = type.to_s
          type unless type.empty?
        end
      end

      # Derive the database range type for a multirange database type
      # (e.g. 'int4multirange' => 'int4range').
      def range_type_for_multirange(type)
        if (type = normalize_db_type(type)) && type =~ /multirange\z/
          type.sub(/multirange\z/, 'range')
        end
      end

      # Derive the database multirange type for a database range type
      # (e.g. 'int4range' => 'int4multirange').
      def multirange_type_for_range(type)
        type.sub(/(range)?\z/, 'multirange')
      end

      # Return the common database range type for the operation, raising
      # if the arguments use different database types.
      def compatible_db_type(left_type, right_type)
        if left_type && right_type && left_type != right_type
          raise Sequel::Error, "cannot compute set operations on ranges with different database types: #{left_type} and #{right_type}"
        end
        left_type || right_type
      end

      # Return the successor function to use for discrete normalization,
      # or nil if the ranges should be treated as continuous.  If all
      # endpoints are of a discrete class (Integer or Date), the
      # successor for that class is used; any continuous endpoint makes
      # the operation continuous.
      def discrete_successor(left_ranges, right_ranges, opts)
        return opts[:successor] if opts[:successor]

        successor = nil
        (left_ranges + right_ranges).each do |range|
          next if range.empty?
          [range.begin, range.end].each do |endpoint|
            next if endpoint.nil?
            if s = DISCRETE_SUCCESSORS[endpoint.class]
              successor ||= s
            else
              return nil
            end
          end
        end
        successor
      end

      # Convert the ranges to a sorted, non-overlapping list of
      # intervals, dropping empty ranges.  If a successor function is
      # given, normalize to half-open [) intervals; otherwise, keep the
      # inclusive/exclusive flags of the bounds.
      def normalize_ranges(ranges, successor)
        intervals = []
        ranges.each do |range|
          next if range.empty?
          if successor
            lower = range.begin
            lower = successor.call(lower) if lower && range.exclude_begin?
            upper = range.end
            upper = successor.call(upper) if upper && !range.exclude_end?
            next if lower && upper && compare_values(lower, upper) >= 0
            intervals << [lower, true, upper, false]
          else
            lower = range.begin
            upper = range.end
            if lower && upper
              cmp = compare_values(lower, upper)
              next if cmp > 0 || (cmp == 0 && (range.exclude_begin? || range.exclude_end?))
            end
            intervals << [lower, !range.exclude_begin?, upper, !range.exclude_end?]
          end
        end
        merge_intervals(intervals)
      end

      # Compare two endpoint values, raising if they are not comparable.
      def compare_values(a, b)
        cmp = begin
          a <=> b
        rescue StandardError
          nil
        end
        unless cmp
          raise Sequel::Error, "cannot compare range endpoints #{a.inspect} and #{b.inspect}"
        end
        cmp
      end

      # Compare two lower bounds, where a nil value is unbounded (smaller
      # than any value), and for equal values an inclusive bound is
      # smaller than an exclusive bound.
      def compare_lowers(v1, i1, v2, i2)
        return 0 if v1.nil? && v2.nil?
        return -1 if v1.nil?
        return 1 if v2.nil?
        cmp = compare_values(v1, v2)
        return cmp unless cmp == 0
        i1 == i2 ? 0 : (i1 ? -1 : 1)
      end

      # Compare two upper bounds, where a nil value is unbounded (larger
      # than any value), and for equal values an inclusive bound is
      # larger than an exclusive bound.
      def compare_uppers(v1, i1, v2, i2)
        return 0 if v1.nil? && v2.nil?
        return 1 if v1.nil?
        return -1 if v2.nil?
        cmp = compare_values(v1, v2)
        return cmp unless cmp == 0
        i1 == i2 ? 0 : (i1 ? 1 : -1)
      end

      # Sort the intervals by lower bound and merge overlapping or
      # adjacent intervals, returning a sorted, non-overlapping list.
      def merge_intervals(intervals)
        merged = []
        intervals.sort{|a, b| compare_lowers(a[0], a[1], b[0], b[1])}.each do |interval|
          if merged.empty?
            merged << interval
          else
            last = merged[-1]
            if touches?(last, interval)
              if compare_uppers(last[2], last[3], interval[2], interval[3]) < 0
                last[2] = interval[2]
                last[3] = interval[3]
              end
            else
              merged << interval
            end
          end
        end
        merged
      end

      # Whether the upper bound of interval a touches or passes the lower
      # bound of interval b, where a is sorted before b.
      def touches?(a, b)
        return true if a[2].nil? || b[0].nil?
        cmp = compare_values(a[2], b[0])
        cmp > 0 || (cmp == 0 && (a[3] || b[1]))
      end

      # Whether the interval contains at least one point.
      def valid_interval?(interval)
        lower, lower_inc, upper, upper_inc = interval
        return true if lower.nil? || upper.nil?
        cmp = compare_values(lower, upper)
        cmp < 0 || (cmp == 0 && lower_inc && upper_inc)
      end

      # Compute the intersection of two sorted, non-overlapping interval
      # lists.
      def intersect_intervals(a_list, b_list)
        intervals = []
        i = j = 0
        while i < a_list.length && j < b_list.length
          a = a_list[i]
          b = b_list[j]
          lower = compare_lowers(a[0], a[1], b[0], b[1]) >= 0 ? a : b
          upper_cmp = compare_uppers(a[2], a[3], b[2], b[3])
          upper = upper_cmp <= 0 ? a : b
          interval = [lower[0], lower[1], upper[2], upper[3]]
          intervals << interval if valid_interval?(interval)
          if upper_cmp < 0
            i += 1
          elsif upper_cmp > 0
            j += 1
          else
            i += 1
            j += 1
          end
        end
        intervals
      end

      # Compute the difference of two sorted, non-overlapping interval
      # lists (intervals in a_list but not in any interval in b_list).
      def difference_intervals(a_list, b_list)
        intervals = []
        a_list.each do |a|
          pieces = [a]
          b_list.each do |b|
            break if pieces.empty?
            pieces = pieces.flat_map{|piece| subtract_interval(piece, b)}
          end
          intervals.concat(pieces)
        end
        intervals
      end

      # Subtract interval b from interval p, returning an array of zero,
      # one, or two intervals.
      def subtract_interval(p, b)
        lower = compare_lowers(p[0], p[1], b[0], b[1]) >= 0 ? p : b
        upper = compare_uppers(p[2], p[3], b[2], b[3]) <= 0 ? p : b
        return [p] unless valid_interval?([lower[0], lower[1], upper[2], upper[3]])

        pieces = []
        unless b[0].nil?
          left = [p[0], p[1], b[0], !b[1]]
          pieces << left if valid_interval?(left)
        end
        unless b[2].nil?
          right = [b[2], !b[3], p[2], p[3]]
          pieces << right if valid_interval?(right)
        end
        pieces
      end

      # Build a normalized PGMultiRange from a sorted, non-overlapping
      # interval list.  Intervals over discrete domains (normalized with
      # a successor function) are returned in PostgreSQL's canonical [)
      # form.
      def build_multirange(intervals, db_type, successor)
        ranges = intervals.map do |lower, lower_inc, upper, upper_inc|
          if successor
            PGRange.new(lower, upper, :exclude_begin=>lower.nil?, :exclude_end=>true, :db_type=>db_type)
          else
            PGRange.new(lower, upper, :exclude_begin=>lower.nil? ? true : !lower_inc, :exclude_end=>upper.nil? ? true : !upper_inc, :db_type=>db_type)
          end
        end
        PGMultiRange.new(ranges, db_type && multirange_type_for_range(db_type))
      end
    end
  end

  module SQL::Builders
    # Convert the object to a Postgres::PGRange.
    def pg_range(v, db_type=nil)
      case v
      when Postgres::PGRange
        if db_type.nil? || v.db_type == db_type
          v
        else
          Postgres::PGRange.new(v.begin, v.end, :exclude_begin=>v.exclude_begin?, :exclude_end=>v.exclude_end?, :db_type=>db_type)
        end
      when Range
        Postgres::PGRange.from_range(v, db_type)
      else
        # May not be defined unless the pg_range_ops extension is used
        pg_range_op(v)
      end
    end
  end

  Database.register_extension(:pg_range, Postgres::PGRange::DatabaseMethods)
end

# simplecov:disable
if Sequel.core_extensions?
  class Range 
    # Create a new PGRange using the receiver as the input range,
    # with the given database type.
    def pg_range(db_type=nil)
      Sequel::Postgres::PGRange.from_range(self, db_type)
    end
  end
end

if defined?(Sequel::CoreRefinements)
  module Sequel::CoreRefinements
    refine Range do
      def pg_range(db_type=nil)
        Sequel::Postgres::PGRange.from_range(self, db_type)
      end
    end
  end
end
# simplecov:enable
