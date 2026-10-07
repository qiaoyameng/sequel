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
    #   # Move multiple entries as a group, optionally to another list
    #   Item.move_many([id1, id2], 3)
    #   Item.move_many([id1, id2], 1, user_id: 2)
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
        model.list_scope_columns = []
        model.dataset = model.dataset.order_prepend(model.position_field)
        model.instance_exec do
          @top_of_list = opts[:top] || 1
        end
        
        model.scope_proc = case scope = opts[:scope]
        when Symbol
          model.list_scope_columns = [scope]
          model.dataset = model.dataset.order_prepend(scope)
          proc{|obj| obj.model.where(scope=>obj.public_send(scope))}
        when Array
          model.list_scope_columns = scope
          model.dataset = model.dataset.order_prepend(*scope)
          proc{|obj| obj.model.where(scope.map{|s| [s, obj.get_column_value(s)]})}
        else
          scope
        end
      end

      module ClassMethods
        # The column name holding the position in the list, as a symbol.
        attr_accessor :position_field

        # Columns that identify a row's list when :scope is configured with
        # column names.
        attr_accessor :list_scope_columns

        # A proc that scopes the dataset, so that there can be multiple positions 
        # in the list, but the positions are unique with the scoped dataset. This
        # proc should accept an instance and return a dataset representing the list.
        attr_accessor :scope_proc

        # An Integer to use as the position of the top of the list. Defaults to 1.
        attr_reader :top_of_list

        Plugins.inherited_instance_variables(
          self,
          :@position_field=>nil,
          :@list_scope_columns=>nil,
          :@scope_proc=>nil,
          :@top_of_list=>nil
        )

        # Move the given primary keys to +target_position+, preserving the
        # order in which the primary keys are provided. Target position is
        # interpreted after removing the moved rows. With column-based scopes,
        # target scope values can be provided to move the rows to another list.
        #
        # Returns the number of rows whose position or scope changed. Raises
        # if primary keys are duplicated or missing, or if they currently come
        # from more than one list.
        def move_many(primary_keys, target_position, target_scope=nil, **target_scope_opts)
          pk_columns = Array(primary_key)
          keys = list_move_many_keys(primary_keys, pk_columns)
          position = position_field

          selected_rows = dataset.where(list_move_many_pk_filter(keys, pk_columns)).all
          if selected_rows.length != keys.length
            raise Error, "not all primary keys exist in #{self}"
          end

          rows_by_key = selected_rows.each_with_object({}) do |row, rows|
            rows[list_move_many_key(row, pk_columns)] = row
          end
          selected = keys.map{|key| rows_by_key.fetch(key)}

          source_scope = list_move_many_scope_identity(selected.first)
          selected.each do |row|
            unless list_move_many_same_scope?(selected.first, row)
              raise Error, "all moved entries must currently be in the same list"
            end
            raise Error, "moved entries must have a position" if row[position].nil?
          end

          target_scope = list_move_many_target_scope(target_scope, target_scope_opts, source_scope)
          same_scope = target_scope == source_scope

          source_rows = list_move_many_scope_dataset(source_scope, selected.first).all
          source_rows.each do |row|
            raise Error, "list entries must have a position" if row[position].nil?
          end

          target_rows = same_scope ? source_rows : list_move_many_scope_dataset(target_scope, selected.first).all
          target_rows.each do |row|
            raise Error, "list entries must have a position" if row[position].nil?
          end

          selected_key_set = keys.dup
          remaining_target = target_rows.reject do |row|
            selected_key_set.include?(list_move_many_key(row, pk_columns))
          end.sort_by{|row| row[position]}

          target_index = target_position.to_i - top_of_list
          target_index = 0 if target_index < 0
          target_index = remaining_target.length if target_index > remaining_target.length

          final_positions = {}
          final_rows = remaining_target[0, target_index] + selected + remaining_target[target_index..-1]
          final_rows.each_with_index do |row, index|
            final_positions[list_move_many_key(row, pk_columns)] = top_of_list + index
          end

          unless same_scope
            source_rows.reject do |row|
              selected_key_set.include?(list_move_many_key(row, pk_columns))
            end.sort_by{|row| row[position]}.each_with_index do |row, index|
              final_positions[list_move_many_key(row, pk_columns)] = top_of_list + index
            end
          end

          selected_changed = selected.select do |row|
            key = list_move_many_key(row, pk_columns)
            !same_scope || final_positions[key] != row[position]
          end
          affected_rows = same_scope ? target_rows : source_rows + target_rows
          other_changed = affected_rows.reject do |row|
            selected_key_set.include?(list_move_many_key(row, pk_columns))
          end.select do |row|
            key = list_move_many_key(row, pk_columns)
            final_positions.key?(key) && final_positions[key] != row[position]
          end

          changed_count = selected_changed.length + other_changed.length
          return changed_count if changed_count == 0

          temporary_rows = selected_changed + other_changed
          temporary_positions = list_move_many_temporary_positions(
            selected_changed, other_changed, affected_rows, same_scope,
            target_scope, final_positions, pk_columns
          )

          db.transaction do
            unless temporary_rows.empty?
              temporary_values = {}
              unless same_scope
                list_scope_columns.each do |column|
                  conditions = selected_changed.map do |row|
                    [list_move_many_pk_expression(row, pk_columns), target_scope[column]]
                  end
                  temporary_values[column] = Sequel.case(conditions, Sequel[column])
                end
              end

              conditions = temporary_rows.map do |row|
                key = list_move_many_key(row, pk_columns)
                [list_move_many_pk_expression(row, pk_columns), temporary_positions[key]]
              end
              temporary_values[position] = list_move_many_case(position, conditions)
              temporary_keys = temporary_rows.map{|row| list_move_many_key(row, pk_columns)}
              dataset.where(list_move_many_pk_filter(temporary_keys, pk_columns)).
                update(temporary_values)
            end

            unless selected_changed.empty?
              values = {}
              unless same_scope
                list_scope_columns.each{|column| values[column] = target_scope[column]}
              end

              conditions = selected_changed.map do |row|
                key = list_move_many_key(row, pk_columns)
                [list_move_many_pk_expression(row, pk_columns), final_positions[key]]
              end
              values[position] = list_move_many_case(position, conditions)
              selected_keys = selected_changed.map{|row| list_move_many_key(row, pk_columns)}
              dataset.where(list_move_many_pk_filter(selected_keys, pk_columns)).
                update(values)
            end

            unless other_changed.empty?
              conditions = other_changed.map do |row|
                key = list_move_many_key(row, pk_columns)
                [list_move_many_pk_expression(row, pk_columns), final_positions[key]]
              end
              other_keys = other_changed.map{|row| list_move_many_key(row, pk_columns)}
              dataset.where(list_move_many_pk_filter(other_keys, pk_columns)).
                update(position => list_move_many_case(position, conditions))
            end
          end

          changed_count
        end

        private

        def list_move_many_keys(primary_keys, pk_columns)
          keys = primary_keys.is_a?(Array) ? primary_keys : raise(Error, "primary keys must be provided as an array")
          raise Error, "must provide at least one primary key" if keys.empty?

          keys = keys.map do |key|
            if pk_columns.length == 1
              key
            else
              values = Array(key)
              unless values.length == pk_columns.length
                raise Error, "composite primary keys must have #{pk_columns.length} values"
              end
              values
            end
          end

          if keys.uniq.length != keys.length
            raise Error, "primary keys must not be duplicated"
          end
          keys
        end

        def list_move_many_key(row, pk_columns)
          values = pk_columns.map{|column| row[column]}
          pk_columns.length == 1 ? values.first : values
        end

        def list_move_many_pk_filter(keys, pk_columns)
          if pk_columns.length == 1
            {pk_columns.first => keys}
          else
            {pk_columns => keys}
          end
        end

        def list_move_many_pk_expression(row, pk_columns)
          values = pk_columns.each_with_object({}) do |column, expression|
            expression[column] = row[column]
          end
          Sequel.expr(values)
        end

        def list_move_many_scope_values(row)
          list_scope_columns.each_with_object({}) do |column, scope|
            scope[column] = row[column]
          end
        end

        def list_move_many_scope_identity(row)
          if list_scope_columns.empty?
            scope_proc ? scope_proc.call(load(row)).sql : nil
          else
            list_move_many_scope_values(row)
          end
        end

        def list_move_many_same_scope?(first_row, row)
          list_move_many_scope_identity(first_row) == list_move_many_scope_identity(row)
        end

        def list_move_many_target_scope(target_scope, target_scope_opts, source_scope)
          if target_scope.nil? && !target_scope_opts.empty?
            target_scope = target_scope_opts[:scope] || target_scope_opts
          end

          if scope_proc.nil?
            raise Error, "model is not scoped" if target_scope
            return source_scope
          end
          return source_scope if target_scope.nil?
          raise Error, "can only move between scopes when the list scope uses columns" if list_scope_columns.empty?

          if target_scope.is_a?(Hash)
            scope = target_scope.each_with_object({}) do |(column, value), normalized|
              normalized[column.to_sym] = value
            end
          elsif list_scope_columns.length == 1
            scope = {list_scope_columns.first => target_scope}
          elsif target_scope.is_a?(Array)
            unless target_scope.length == list_scope_columns.length
              raise Error, "target scope must contain #{list_scope_columns.inspect}"
            end
            scope = Hash[list_scope_columns.zip(target_scope)]
          elsif target_scope.respond_to?(:[])
            scope = list_scope_columns.each_with_object({}) do |column, normalized|
              normalized[column] = target_scope[column]
            end
          else
            raise Error, "target scope must contain #{list_scope_columns.inspect}"
          end

          expected_columns = list_scope_columns.sort_by(&:to_s)
          unless scope.keys.sort_by(&:to_s) == expected_columns
            raise Error, "target scope must contain exactly #{list_scope_columns.inspect}"
          end
          scope
        end

        def list_move_many_scope_dataset(scope_values, row)
          return dataset unless scope_proc
          return scope_proc.call(load(row)) if list_scope_columns.empty?
          dataset.where(scope_values)
        end

        def list_move_many_temporary_positions(
          selected_rows, other_rows, affected_rows, same_scope,
          target_scope, final_positions, pk_columns
        )
          positions = {}
          temporary_positions = {}
          current_max = affected_rows.map{|row| row[position_field]}.max.to_i
          final_max = final_positions.values.max.to_i
          next_position = [current_max, final_max].max + 1

          affected_rows.each do |row|
            scope = list_move_many_scope_identity(row)
            positions[scope] ||= {}
            positions[scope][row[position_field]] = true
          end

          changed_rows = same_scope ? other_rows + selected_rows : selected_rows + other_rows
          changed_rows.each do |row|
            key = list_move_many_key(row, pk_columns)
            is_selected = selected_rows.any? do |selected_row|
              list_move_many_key(selected_row, pk_columns) == key
            end
            scope = if !same_scope && is_selected
              target_scope
            else
              list_move_many_scope_identity(row)
            end

            scope_positions = positions[scope] ||= {}
            next_position += 1 while scope_positions.key?(next_position)
            temporary_positions[key] = next_position
            scope_positions[next_position] = true
          end

          temporary_positions
        end

        def list_move_many_case(position, conditions)
          Sequel.case(conditions, Sequel[position])
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
