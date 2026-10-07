# frozen-string-literal: true

module Sequel
  # Raised when a model destroy is blocked by an association_dependencies plugin
  # :restrict action because associated objects still exist.
  class AssociationDependencyRestriction < Sequel::Error
    # The model instance whose destroy was attempted.
    attr_reader :root_object

    # Human-readable association path from the root object to the blocking association.
    attr_reader :association_path

    # Array with up to Plugins::AssociationDependencies::RESTRICTION_EXAMPLE_KEYS
    # primary key hashes of associated objects that caused the restriction.
    attr_reader :example_keys

    def initialize(message, root_object, association_path, example_keys)
      @root_object = root_object
      @association_path = association_path
      @example_keys = example_keys
      super(message)
    end
  end

  module Plugins
    # The association_dependencies plugin allows you do easily set up before and/or after destroy hooks
    # for destroying, deleting, nullifying, or restricting associated model objects.  The following
    # association types support the following dependency actions:
    #
    # :many_to_many :: :nullify (removes all related entries in join table), :restrict
    # :many_to_one :: :delete, :destroy, :restrict
    # :one_to_many, :one_to_one :: :delete, :destroy, :nullify (sets foreign key to NULL for all associated objects), :restrict
    #
    # This plugin works directly with the association datasets and does not use any cached association values.
    # The :delete action will delete all associated objects from the database in a single SQL call.
    # The :destroy action will load each associated object from the database and call the destroy method on it.
    # The :restrict action prevents the object from being destroyed when associated objects exist.
    #
    # To set up an association dependency, you must provide a hash with association name symbols
    # and dependency action values.  You can provide the hash to the plugin call itself or
    # to the add_association_dependencies method:
    #
    #   Business.plugin :association_dependencies, address: :delete
    #   # or:
    #   Artist.plugin :association_dependencies
    #   Artist.add_association_dependencies albums: :destroy, reviews: :delete, tags: :nullify
    #
    # == restrict action
    #
    # The :restrict action implements a "never destroy while associated objects exist" rule:
    #
    #   Artist.add_association_dependencies albums: :restrict
    #   artist.destroy # raises Sequel::AssociationDependencyRestriction if the artist has any albums
    #
    # Before any object is destroyed, the plugin walks the entire dependency graph that would be
    # affected by the destroy (the root object plus every object reached through :destroy
    # dependencies, recursively) and checks every :restrict dependency of every object in that
    # graph using the association dataset.  Only if all checks pass do the actual dependency
    # actions and the model +before_destroy+, +around_destroy+, and +after_destroy+ hooks run.
    # So a destroy that would be blocked performs no SQL writes and invokes no destroy hooks,
    # even when one branch of the dependency graph could be processed before a later branch is
    # found to be blocked.
    #
    # Objects appearing in more than one place in the graph (shared or self-referential
    # associations, such as cyclic relationships) are only checked once, keyed by model and
    # full primary key.  Composite primary keys use all primary key columns, never just one.
    # When a restriction is found, the raised Sequel::AssociationDependencyRestriction reports
    # the root object, a finite human-readable association path from the root to the blocking
    # association, and a limited number of example associated primary keys:
    #
    #   begin
    #     artist.destroy
    #   rescue Sequel::AssociationDependencyRestriction => e
    #     e.root_object      #=> #<Artist @values={:id=>1}>
    #     e.association_path #=> "albums -> tags"
    #     e.example_keys     #=> [{:id=>4}, {:id=>7}]
    #   end
    #
    # The check runs inside the same database transaction as the destroy itself
    # (Model#destroy already wraps +_destroy+ in a transaction).  Because the existence checks
    # are separate statements from the deletes, a concurrent transaction can still insert an
    # associated row after the check but before the delete unless the database itself enforces
    # the relationship with a foreign key constraint (or the transaction uses an appropriate
    # isolation level).  The :restrict action is a business-level guard, not a replacement for
    # database constraints.
    #
    # Note that objects only reachable through :delete and :nullify dependencies are not loaded
    # as model instances, so their own :restrict dependencies are not checked.  Use :destroy
    # dependencies if the associated objects must be checked (and have their hooks run).
    module AssociationDependencies
      # Mapping of association types to when the dependency calls should be made (either
      # :before for in before_destroy or :after for in after_destroy).  :restrict actions
      # are not run from these hooks, they are checked up front in _destroy.
      ASSOCIATION_MAPPING = {:one_to_many=>:before, :many_to_one=>:after, :many_to_many=>:before, :one_to_one=>:before}.freeze

      # The valid dependence actions
      DEPENDENCE_ACTIONS = [:delete, :destroy, :nullify, :restrict].freeze

      # Maximum number of blocking associations reported by a single failed destroy.
      RESTRICTION_LIMIT = 10

      # Number of example primary keys included for each blocking association.
      RESTRICTION_EXAMPLE_KEYS = 3

      # Separator used in the reported association path.
      RESTRICTION_PATH_SEPARATOR = ' -> '.freeze

      # Initialize the association_dependencies hash for this model.
      def self.apply(model, hash=OPTS)
        model.instance_exec{@association_dependencies = {:before_delete=>[], :before_destroy=>[], :before_nullify=>[], :before_restrict=>[], :after_delete=>[], :after_destroy=>[], :after_restrict=>[]}}
      end

      # Call add_association_dependencies with any dependencies given in the plugin call.
      def self.configure(model, hash=OPTS)
        model.add_association_dependencies(hash) unless hash.empty?
      end

      module ClassMethods
        # A hash specifying the association dependencies for each model.  The keys
        # are symbols indicating the type of action and when it should be executed
        # (e.g. :before_delete).  Values are an array of method symbols.
        # For before_nullify, the symbols are remove_all_association methods.  For the
        # restrict arrays, the symbols are association name symbols.  For other
        # types, the symbols are association_dataset methods, on which delete or
        # destroy is called.
        attr_reader :association_dependencies

        # Add association dependencies to this model.  The hash should have association name
        # symbol keys and dependency action symbol values (e.g. albums: :destroy).
        def add_association_dependencies(hash)
          hash.each do |association, action|
            raise(Error, "Nonexistent association: #{association}") unless r = association_reflection(association)
            type = r[:type]
            raise(Error, "Invalid dependence action type: association: #{association}, dependence action: #{action}") unless DEPENDENCE_ACTIONS.include?(action)
            raise(Error, "Invalid association type: association: #{association}, type: #{type}") unless time = ASSOCIATION_MAPPING[type]
            if action == :nullify
              association_dependencies[:before_nullify] << case type
              when :one_to_many , :many_to_many
                [r[:remove_all_method]]
              when :one_to_one
                [r[:setter_method], nil]
              else
                raise(Error, "Can't nullify many_to_one associated objects: association: #{association}")
              end
            elsif action == :restrict
              association_dependencies[:"#{time}_restrict"] << association
            else
              raise(Error, "Can only nullify many_to_many associations: association: #{association}") if type == :many_to_many
              association_dependencies[:"#{time}_#{action}"] << r[:dataset_method]
            end
          end
        end

        # Whether destroying instances of this model can encounter a :restrict
        # dependency, either directly or through a chain of :destroy
        # dependencies.  Used to skip the up-front graph walk entirely when no
        # restriction can possibly fire.  Cyclic associations between models
        # terminate through the visiting hash.
        def restriction_graph?
          send(:compute_restriction_graph?, {})
        end

        # Freeze association dependencies when freezing model class.
        def freeze
          @association_dependencies.freeze.each_value(&:freeze)

          super
        end

        private

        # Recursive helper for restriction_graph?, tracking models already being
        # examined so cyclic associations don't loop forever.
        def compute_restriction_graph?(visiting)
          return visiting[object_id] if visiting.key?(object_id)
          visiting[object_id] = false

          deps = association_dependencies
          has_restrict = !(deps[:before_restrict].empty? && deps[:after_restrict].empty?)
          has_restrict || (deps[:before_destroy] | deps[:after_destroy]).any? do |dataset_method|
            association_name = dataset_method.to_s.chomp('_dataset').to_sym
            associated = association_reflection(association_name).associated_class
            associated.send(:compute_restriction_graph?, visiting)
          end.tap{|result| visiting[object_id] = result}
        end

        Plugins.inherited_instance_variables(self, :@association_dependencies=>:hash_dup)
      end

      module InstanceMethods
        # Check the entire dependency graph for blocking :restrict associations before
        # running any hooks or dependency actions.  Runs inside Model#destroy's
        # transaction, so a failure rolls back the whole destroy without any write or
        # hook having taken effect.
        def _destroy(opts=OPTS)
          check_association_dependency_restrictions! if model.restriction_graph?
          super
        end

        # Run the delete and destroy association dependency actions for
        # many_to_one associations.
        def after_destroy
          super
          model.association_dependencies[:after_delete].each{|m| public_send(m).delete}
          model.association_dependencies[:after_destroy].each{|m| public_send(m).destroy}
        end

        # Run the delete, destroy, and nullify association dependency actions for
        # *_to_many associations.
        def before_destroy
          model.association_dependencies[:before_delete].each{|m| public_send(m).delete}
          model.association_dependencies[:before_destroy].each{|m| public_send(m).destroy}
          model.association_dependencies[:before_nullify].each{|args| public_send(*args)}
          super
        end

        private

        # Walk the whole graph of objects this destroy would cascade through via
        # :destroy dependencies, and verify every :restrict dependency of every object
        # in that graph.  Raises AssociationDependencyRestriction describing the
        # blocking associations found (up to RESTRICTION_LIMIT).
        def check_association_dependency_restrictions!
          blockers = []

          # Each queue entry is [instance, path parts from the root].  Objects are
          # visited once per [model, full primary key] so shared subobjects and
          # cyclic associations terminate and each reported path stays finite.
          queue = [[self, []]]
          visited = {restriction_visit_key(self) => true}

          until queue.empty?
            object, path_parts = queue.shift
            dependencies = object.model.association_dependencies

            (dependencies[:before_restrict] | dependencies[:after_restrict]).each do |association_name|
              associated_model = object.model.association_reflection(association_name).associated_class
              keys = restriction_example_keys(object.public_send(:"#{association_name}_dataset"), associated_model)
              next if keys.empty?

              blockers << restriction_blocker(path_parts, association_name, associated_model, keys)
              return raise_association_restriction(blockers) if blockers.length >= RESTRICTION_LIMIT
            end

            # Only :destroy dependencies cascade into model instances whose own
            # dependencies need checking.  :delete and :nullify dependencies never
            # instantiate the associated rows, so their graphs are not walked.
            (dependencies[:before_destroy] | dependencies[:after_destroy]).each do |dataset_method|
              association_name = dataset_method.to_s.chomp('_dataset').to_sym
              child_path_parts = path_parts + [association_name]

              object.public_send(dataset_method).all.each do |associated|
                key = restriction_visit_key(associated)
                next if visited.key?(key)
                visited[key] = true
                queue << [associated, child_path_parts]
              end
            end
          end

          raise_association_restriction(blockers) unless blockers.empty?
        end

        # Fetch up to RESTRICTION_EXAMPLE_KEYS example rows from the association
        # dataset selecting the full primary key columns (all of them for composite
        # keys), returning primary key value hashes.  Uses the live association
        # dataset, never cached association values.
        def restriction_example_keys(dataset, associated_model)
          pk_columns = Array(associated_model.primary_key)
          rows = dataset.limit(RESTRICTION_EXAMPLE_KEYS).select(*pk_columns).all
          rows.map do |row|
            pk_columns.map{|c| [c, row.values[c]]}.to_h
          end
        end

        # Identity key for graph traversal: model plus the complete primary key tuple,
        # so composite-key objects are never identified by a single column.
        def restriction_visit_key(object)
          [object.model, Array(object.pk)]
        end

        # Build a description of one blocking association for the error message.
        def restriction_blocker(path_parts, association_name, associated_model, keys)
          path = (path_parts + [association_name]).map(&:to_s).join(RESTRICTION_PATH_SEPARATOR)
          {:path=>path, :associated_model=>associated_model, :keys=>keys}
        end

        # Raise AssociationDependencyRestriction with a readable message listing
        # every blocker, and the root object and first blocker's path/examples
        # exposed on the exception.
        def raise_association_restriction(blockers)
          descriptions = blockers.map do |blocker|
            "  #{blocker[:path]} (#{blocker[:associated_model].name || blocker[:associated_model]}): #{blocker[:keys].inspect}"
          end

          raise AssociationDependencyRestriction.new(
            "cannot destroy #{model.name || model} #{pk.inspect} due to restricted associations:\n#{descriptions.join("\n")}",
            self,
            blockers.first[:path],
            blockers.first[:keys]
          )
        end
      end
    end
  end
end
