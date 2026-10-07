# frozen-string-literal: true

module Sequel
  module Plugins
    # The list plugin allows for model instances to be part of an ordered list,
    # based on a position field in the database.  It can either consider all
    # rows in the table as being from the same list, or you can specify scopes
    # so that multiple lists can be kept in the same table.
    # 
    # Basic Example:
    #
    #   class Item < Sequel::Model(:items)
    #     plugin :list # will use :position field for position
    #     plugin :list, field: :pos # will use :pos field for position
    #   end
    #   
    #   item = Item[1]
    # 
    #   # Get the next or previous item in the list
    # 
    #   item.next
    #   item.prev
    # 
    #   # Modify the item's position, which may require modifying other items in
    #   # the same list
    # 
    #   item.move_to(3)
    #   item.move_to_top
    #   item.move_to_bottom
    #   item.move_up
    #   item.move_down
    #
    #   # Move multiple items together, optionally to another list scope:
    #
    #   Item.move_many([item1.id, item2.id], 3)
    #   Item.move_many([item1.id, item2.id], 3, scope: 2)
    # 
    # You can provide a <tt>:scope</tt> option to scope the list.  This option
    # can be a symbol or array of symbols specifying column name(s), or a proc
    # that accepts a model instance and returns a dataset representing the list
    # the object is in.  You will need to provide a <tt>:scope</tt> option if
    # the model's dataset uses a subquery (such as when using the class_table_inheritance
    # plugin).
    # 
    # For example, if each item has a +user_id+ field, and you want every user
    # to have their own list:
    #
    #   Item.plugin :list, scope: :user_id
    # 
    # Note that using this plugin modifies the order of the model's dataset to
    # sort by the position and scope fields.  Also note that this plugin is subject to
    # race conditions, and is not safe when concurrent modifications are made
    # to the same list.
    #
    # Note that by default, unlike ruby arrays, the list plugin assumes the first
    # entry in the list has position 1, not position 0.
    #
    # You can change this by providing an integer <tt>:top</tt> option:
    #
    #   Item.plugin :list, top: 0
    #
    # Copyright (c) 2007-2010 Sharon Rosner, Wayne E. Seguin, Aman Gupta, Adrian Madrid, Jeremy Evans
    module List
      # Set the +position_field+, +scope_proc+ and +top_of_list+ attributes for the model,
      # using the <tt>:field</tt>, <tt>:scope</tt>, and <tt>:top</tt> options, respectively.
      # The <tt>:scope</tt> option can be a symbol, array of symbols, or a proc that
      # accepts a model instance and returns a dataset representing the list.
      # Also, modify the model dataset's order to order by the position and scope fields.
      def self.configure(model, opts = OPTS)
        model.position_field = opts[:field] || :position
        model.scope_fields = case scope = opts[:scope]
        when Symbol
          [scope]
        when Array
          scope.dup
        end
        model.dataset = model.dataset.order_prepend(model.position_field)
        model.instance_exec do
          @top_of_list = opts[:top] || 1
        end
        
        model.scope_proc = case scope = opts[:scope]
        when Symbol
          model.dataset = model.dataset.order_prepend(scope)
          proc{|obj| obj.model.where(scope=>obj.public_send(scope))}
        when Array
          model.dataset = model.dataset.order_prepend(*scope)
          proc{|obj| obj.model.where(scope.map{|s| [s, obj.get_column_value(s)]})}
        else
          scope
        end
      end

      module ClassMethods
        # The column name holding the position in the list, as a symbol.
        attr_accessor :position_field

        # A proc that scopes the dataset, so that there can be multiple positions 
        # in the list, but the positions are unique with the scoped dataset. This
        # proc should accept an instance and return a dataset representing the list.
        attr_accessor :scope_proc

        # The scope field name(s) used by the list plugin, as an array.
        attr_accessor :scope_fields

        # An Integer to use as the position of the top of the list. Defaults to 1.
        attr_reader :top_of_list

        Plugins.inherited_instance_variables(self, :@position_field=>nil, :@scope_proc=>nil, :@scope_fields=>nil, :@top_of_list=>nil)

        # Move the given primary keys as a group to +target_position+, preserving
        # the order of the given primary keys. If +scope+ is given, move the
        # members to that list scope. Both the source and target positions are
        # interpreted in the list after the moved members have been removed.
        #
        # Returns the number of rows updated. Raises if the primary keys are
        # duplicated, any member is missing, the members are from multiple
        # source scopes, or the target scope cannot be used. The movement is
        # made in a transaction so a database constraint failure does not leave
        # temporary positions or partially modified rows.
        def move_many(pks, target_position, scope: MOVE_MANY_SCOPE_NOT_GIVEN)
          pks = move_many_pks(pks)
          moved_objects = move_many_objects(pks)
          source_scope = move_many_source_scope(moved_objects, scope)
          target_scope = move_many_target_scope(source_scope, scope)

          selected = pks.map do |pk|
            object = moved_objects.fetch(pk)
            position = move_many_position(object)
            {pk: pk, position: position}
          end

          source_dataset = moved_objects.values.first.list_dataset
          target_dataset = scope_fields && target_scope != source_scope ? where(scope_fields.zip(target_scope).to_h) : source_dataset
          cross_scope = target_dataset != source_dataset

          source_remaining = move_many_list_rows(source_dataset.exclude(move_many_pk_condition(pks)))
          target_remaining = cross_scope ? move_many_list_rows(target_dataset) : source_remaining

          move_many_validate_positions(:source, selected.map{|row| row[:position]})
          move_many_validate_positions(:source, source_remaining.map{|row| row[:position]})
          move_many_validate_positions(:target, target_remaining.map{|row| row[:position]}) if cross_scope

          target = move_many_target_position(target_position, target_remaining.length)
          final_rows =
            if cross_scope
              target_remaining[0, target] + selected + (target_remaining[target..] || [])
            else
              source_remaining[0, target] + selected + (source_remaining[target..] || [])
            end

          changes = {}
          if cross_scope
            final_rows.each_with_index do |row, index|
              changes[row[:pk]] = {position: top_of_list + index, scope: target_scope}
            end
            source_remaining.each_with_index do |row, index|
              position = top_of_list + index
              next if row[:position] == position
              changes[row[:pk]] = {position: position, scope: source_scope}
            end
            target_remaining.each do |row|
              final_row = final_rows.find{|final_row| final_row[:pk] == row[:pk]}
              next if final_row[:position] == row[:position]
              changes[row[:pk]] = {position: final_row[:position], scope: target_scope}
            end
          else
            final_rows.each_with_index do |row, index|
              position = top_of_list + index
              next if row[:position] == position
              changes[row[:pk]] = {position: position, scope: target_scope}
            end
          end

          return 0 if changes.empty?

          source_max = move_many_max_position(source_dataset)
          target_max = cross_scope ? move_many_max_position(target_dataset) : source_max
          current_max = [source_max, target_max].compact.map(&:to_i).max
          current_max = top_of_list - 1 if current_max < top_of_list
          temporary_positions = {}
          changes.each_key.with_index(current_max + 1) do |pk, position|
            temporary_positions[pk] = position
          end

          position_expression = Sequel[position_field]
          changed_dataset = dataset.where(move_many_pk_condition(changes.keys))

          db.transaction do
            changed_dataset.update(position_field => Sequel.case(move_many_case_conditions(temporary_positions), position_expression))

            final_positions = changes.each_with_object({}) do |(pk, change), positions|
              positions[pk] = change[:position]
            end
            values = {position_field => Sequel.case(move_many_case_conditions(final_positions), position_expression)}
            if cross_scope
              scope_fields.each_with_index do |field, index|
                field_expression = Sequel[field]
                field_conditions = {}
                changes.each do |pk, change|
                  field_conditions[primary_key_hash(pk)] = change[:scope][index]
                end
                values[field] = Sequel.case(field_conditions, field_expression)
              end
            end

            changed_dataset.update(values)
          end

          changes.length
        end

        private

        MOVE_MANY_SCOPE_NOT_GIVEN = Object.new.freeze

        def move_many_pks(pks)
          unless pks.is_a?(Array) && !pks.empty?
            raise(Error, "move_many requires a non-empty array of primary keys")
          end

          pks = pks.map do |pk|
            if primary_key.is_a?(Array)
              pk = Array(pk)
              unless pk.length == primary_key.length && pk.all?
                raise(Error, "invalid composite primary key given to move_many: #{pk.inspect}")
              end
              pk
            else
              pk
            end
          end

          unless pks.length == pks.uniq.length
            raise(Error, "duplicate primary keys given to move_many")
          end

          pks
        end

        def move_many_objects(pks)
          objects = where(move_many_pk_condition(pks)).all
          objects = objects.each_with_object({}) {|object, hash| hash[object.pk] = object}
          missing = pks.reject{|pk| objects.key?(pk)}
          unless missing.empty?
            raise(Error, "missing list members given to move_many: #{missing.inspect}")
          end
          objects
        end

        def move_many_pk_condition(pks)
          if primary_key.is_a?(Array)
            pks.map{|pk| Sequel.expr(primary_key_hash(pk))}.reduce(:|)
          else
            {primary_key => pks}
          end
        end

        def move_many_position(object)
          position = object.public_send(position_field)
          unless position.is_a?(Integer)
            raise(Error, "list member #{object.pk.inspect} has an invalid position: #{position.inspect}")
          end
          position
        end

        def move_many_source_scope(objects, target_scope)
          if scope_fields
            objects = objects.values
            source_scope = scope_fields.map{|field| objects.first.public_send(field)}
            objects.each do |object|
              scope = scope_fields.map{|field| object.public_send(field)}
              unless scope == source_scope
                raise(Error, "move_many cannot move members from multiple source scopes")
              end
            end
            source_scope
          elsif scope_proc
            unless target_scope.equal?(MOVE_MANY_SCOPE_NOT_GIVEN)
              raise(Error, "move_many cannot move to another scope when the list plugin uses a proc scope")
            end
            objects = objects.values
            source_dataset = objects.first.list_dataset
            unless objects.all?{|object| move_many_same_dataset?(object.list_dataset, source_dataset)}
              raise(Error, "move_many cannot move members from multiple source scopes")
            end
            nil
          else
            unless target_scope.equal?(MOVE_MANY_SCOPE_NOT_GIVEN) || target_scope.nil?
              raise(Error, "move_many cannot use a target scope when the list plugin is unscoped")
            end
            nil
          end
        end

        def move_many_target_scope(source_scope, target_scope)
          return source_scope if target_scope.equal?(MOVE_MANY_SCOPE_NOT_GIVEN)
          return source_scope unless scope_fields

          scope = case target_scope
          when Hash
            unless target_scope.keys.sort == scope_fields.sort
              raise(Error, "invalid target scope given to move_many: #{target_scope.inspect}")
            end
            scope_fields.map{|field| target_scope[field]}
          when Array
            unless target_scope.length == scope_fields.length
              raise(Error, "invalid target scope given to move_many: #{target_scope.inspect}")
            end
            target_scope.dup
          else
            unless scope_fields.length == 1
              raise(Error, "invalid target scope given to move_many: #{target_scope.inspect}")
            end
            [target_scope]
          end

          scope
        end

        def move_many_list_rows(dataset)
          fields = Array(primary_key) + [position_field]
          dataset.select(*fields).order(position_field).map do |row|
            pk = if primary_key.is_a?(Array)
              primary_key.map{|field| row[field]}
            else
              row[primary_key]
            end
            {pk: pk, position: row[position_field]}
          end.sort_by{|row| row[:position]}
        end

        def move_many_validate_positions(name, positions)
          unless positions.all?{|position| position.is_a?(Integer)}
            raise(Error, "#{name} list has invalid positions")
          end
          unless positions.length == positions.uniq.length
            raise(Error, "#{name} list has duplicate positions")
          end
        end

        def move_many_target_position(target_position, remaining_count)
          unless target_position.is_a?(Integer)
            raise(Error, "invalid target position given to move_many: #{target_position.inspect}")
          end

          target = target_position - top_of_list
          target = 0 if target < 0
          target = remaining_count if target > remaining_count
          target
        end

        def move_many_max_position(dataset)
          scope_fields ? dataset.unfiltered.max(position_field) : dataset.max(position_field)
        end

        def move_many_same_dataset?(dataset, source_dataset)
          dataset.sql == source_dataset.sql && dataset.opts[:where] == source_dataset.opts[:where]
        end

        def move_many_case_conditions(values)
          values.each_with_object({}) do |(pk, position), conditions|
            conditions[primary_key_hash(pk)] = position
          end
        end
      end

      module InstanceMethods
        # The model object at the given position in the list containing this instance.
        def at_position(p)
          list_dataset.first(position_field => p)
        end

        # When destroying an instance, move all entries after the instance down
        # one position, so that there aren't any gaps
        def after_destroy
          super

          f = Sequel[position_field]
          list_dataset.where(f > position_value).update(f => f - 1)
        end

        # Find the last position in the list containing this instance.
        def last_position
          list_dataset.max(position_field).to_i
        end

        # A dataset that represents the list containing this instance.
        def list_dataset
          model.scope_proc ? model.scope_proc.call(self) : model.dataset
        end

        # Move this instance down the given number of places in the list,
        # or 1 place if no argument is specified.
        def move_down(n = 1)
          move_to(position_value + n)
        end

        # Move this instance to the given place in the list.  If lp is not
        # given or greater than the last list position, uses the last list
        # position.  If lp is less than the top list position, uses the
        # top list position.
        def move_to(target, lp = nil)
          current = position_value
          if target != current
            checked_transaction do
              ds = list_dataset
              op, ds = if target < current
                target = model.top_of_list if target < model.top_of_list
                [:+, ds.where(position_field=>target...current)]
              else
                lp ||= last_position
                target = lp if target > lp
                [:-, ds.where(position_field=>(current + 1)..target)]
              end
              ds.update(position_field => Sequel::SQL::NumericExpression.new(op, position_field, 1))
              update(position_field => target)
            end
          end
          self
        end

        # Move this instance to the bottom (last position) of the list.
        def move_to_bottom
          lp = last_position 
          move_to(lp, lp)
        end

        # Move this instance to the top (first position, usually position 1) of the list.
        def move_to_top
          move_to(model.top_of_list)
        end

        # Move this instance the given number of places up in the list, or 1 place
        # if no argument is specified.
        def move_up(n = 1)
          move_to(position_value - n) 
        end

        # The model instance the given number of places below this model instance
        # in the list, or 1 place below if no argument is given.
        def next(n = 1)
          n == 0 ? self : at_position(position_value + n)
        end

        # The value of the model's position field for this instance.
        def position_value
          get_column_value(position_field)
        end

        # The model instance the given number of places below this model instance
        # in the list, or 1 place below if no argument is given.
        def prev(n = 1)
          self.next(n * -1)
        end

        # Set the value of the position_field to the maximum value plus 1 unless the
        # position field already has a value. If the list is empty, the position will
        # be set to the model's +top_of_list+ value.
        def before_validation
          unless get_column_value(position_field)
            current_max = list_dataset.max(position_field)
            value = current_max.nil? ? model.top_of_list : current_max.to_i + 1
            set_column_value("#{position_field}=", value)
          end
          super
        end

        private

        # The model's position field, an instance method for ease of use.
        def position_field
          model.position_field
        end
      end

    end
  end
end
