# frozen-string-literal: true

module Sequel
  module Plugins
    # The association_dependencies plugin allows you do easily set up before and/or after destroy hooks
    # for destroying, deleting, nullifying, or restricting on associated model objects.  The following
    # association types support the following dependency actions:
    # 
    # :many_to_many :: :nullify (removes all related entries in join table)
    # :many_to_one :: :delete, :destroy, :restrict
    # :one_to_many, one_to_one :: :delete, :destroy, :nullify (sets foreign key to NULL for all associated objects), :restrict
    #
    # This plugin works directly with the association datasets and does not use any cached association values.
    # The :delete action will delete all associated objects from the database in a single SQL call.
    # The :destroy action will load each associated object from the database and call the destroy method on it.
    # The :restrict action will prevent the object from being destroyed if any associated objects exist.
    #
    # Before any dependent objects are deleted, destroyed, or nullified, and before any destroy hooks
    # are called, the plugin checks the entire dependency graph that the destroy will traverse
    # (following :destroy dependencies recursively) for :restrict violations.  If any associated
    # objects exist for a :restrict dependency, a
    # Sequel::Plugins::AssociationDependencies::RestrictViolation exception is raised before any
    # changes are made to the database, so no branch of the dependency graph is deleted before a
    # later branch is found to be restricted.  The check uses the association datasets (with their
    # real conditions), and does not use possibly stale cached associations.  Shared dependent
    # objects in the graph are only checked once (objects are identified by their class and full
    # primary key, including all columns of composite primary keys), and cyclic dependencies
    # terminate with a finite association path.
    #
    # The restrict check and the actual deletion run in the same database transaction (the plugin
    # wraps the destroy in a transaction if a restrict check is required and one is not already
    # active).  Note that this does not protect against concurrent transactions inserting
    # associated rows between the check and the deletion; for complete protection against
    # concurrent inserts you still need database foreign key constraints and/or an appropriate
    # transaction isolation level (such as serializable).
    #
    # To set up an association dependency, you must provide a hash with association name symbols
    # and dependency action values.  You can provide the hash to the plugin call itself or
    # to the add_association_dependencies method:
    #
    #   Business.plugin :association_dependencies, address: :delete
    #   # or:
    #   Artist.plugin :association_dependencies
    #   Artist.add_association_dependencies albums: :destroy, reviews: :delete, tags: :nullify, fans: :restrict
    module AssociationDependencies
      # The maximum number of example primary keys of existing associated objects
      # to include in RestrictViolation exceptions.
      RESTRICT_VIOLATION_EXAMPLE_KEYS = 5

      # Exception class raised when a :restrict association dependency prevents
      # destroying an object because associated objects exist.
      class RestrictViolation < Sequel::Error
        # The root model object that was being destroyed.
        attr_reader :model

        # The restrict violations found when checking the dependency graph.
        # An array of triples, each containing:
        #
        # * an array of association name symbols giving the path from the
        #   root object to the restricted association (finite even for cyclic
        #   dependencies, since each object in the graph is checked at most once)
        # * the association reflection for the restricted association
        # * an array of up to RESTRICT_VIOLATION_EXAMPLE_KEYS primary keys of
        #   existing associated objects (arrays of values for composite primary keys)
        attr_reader :violations

        def initialize(model, violations)
          @model = model
          @violations = violations
          details = violations.map do |path, reflection, keys|
            "#{path.join(' > ')} (existing #{reflection.associated_class} keys: #{keys.map{|k| k.inspect}.join(', ')})"
          end
          super("cannot destroy #{model.inspect}: restrict association dependency violated at #{details.join('; ')}")
        end
      end

      # Mapping of association types to when the dependency calls should be made (either
      # :before for in before_destroy or :after for in after_destroy)
      ASSOCIATION_MAPPING = {:one_to_many=>:before, :many_to_one=>:after, :many_to_many=>:before, :one_to_one=>:before}.freeze

      # The valid dependence actions
      DEPENDENCE_ACTIONS = [:delete, :destroy, :nullify, :restrict].freeze

      # Initialize the association_dependencies hash for this model.
      def self.apply(model, hash=OPTS)
        model.instance_exec do
          @association_dependencies = {:before_delete=>[], :before_destroy=>[], :before_nullify=>[], :after_delete=>[], :after_destroy=>[], :restrict=>[]}
          @association_dependency_reflections = {:restrict=>[], :destroy=>[]}
        end
      end

      # Call add_association_dependencies with any dependencies given in the plugin call.
      def self.configure(model, hash=OPTS)
        model.add_association_dependencies(hash) unless hash.empty?
      end

      module ClassMethods
        # A hash specifying the association dependencies for each model.  The keys
        # are symbols indicating the type of action and when it should be executed
        # (e.g. :before_delete).  Values are an array of method symbols.
        # For before_nullify, the symbols are remove_all_association methods.  For other
        # types, the symbols are association_dataset methods, on which delete or
        # destroy is called.
        attr_reader :association_dependencies

        # A hash with :restrict and :destroy keys, mapping to arrays of association
        # reflections.  Used to check the dependency graph for restrict violations
        # before destroying.
        attr_reader :association_dependency_reflections

        # Add association dependencies to this model.  The hash should have association name
        # symbol keys and dependency action symbol values (e.g. albums: :destroy).
        def add_association_dependencies(hash)
          hash.each do |association, action|
            raise(Error, "Nonexistent association: #{association}") unless r = association_reflection(association)
            type = r[:type]
            raise(Error, "Invalid dependence action type: association: #{association}, dependence action: #{action}") unless DEPENDENCE_ACTIONS.include?(action)
            raise(Error, "Invalid association type: association: #{association}, type: #{type}") unless time = ASSOCIATION_MAPPING[type]
            if action == :restrict
              raise(Error, "Can only nullify many_to_many associations: association: #{association}") if type == :many_to_many
              association_dependencies[:restrict] << r[:dataset_method]
              association_dependency_reflections[:restrict] << r
            elsif action == :nullify
              association_dependencies[:before_nullify] <<
              case type
              when :one_to_many , :many_to_many
                [r[:remove_all_method]]
              when :one_to_one
                [r[:setter_method], nil]
              else
                raise(Error, "Can't nullify many_to_one associated objects: association: #{association}")
              end
            else
              raise(Error, "Can only nullify many_to_many associations: association: #{association}") if type == :many_to_many
              association_dependency_reflections[:destroy] << r if action == :destroy
              association_dependencies[:"#{time}_#{action}"] << r[:dataset_method]
            end
          end
        end

        # Whether destroying an instance of this class can run into a restrict
        # dependency anywhere in the dependency graph traversed by the destroy
        # (following :destroy dependencies recursively).  Used to skip the
        # restrict check completely for models that cannot be affected by it.
        def association_dependencies_restrict_reachable?(seen={})
          return false if seen[self]
          seen[self] = true
          refs = association_dependency_reflections
          return true unless refs[:restrict].empty?
          refs[:destroy].any? do |r|
            (k = r.associated_class).respond_to?(:association_dependencies_restrict_reachable?) &&
              k.association_dependencies_restrict_reachable?(seen)
          end
        end

        # Freeze association dependencies when freezing model class.
        def freeze
          @association_dependencies.freeze.each_value(&:freeze)
          @association_dependency_reflections.freeze.each_value(&:freeze)

          super
        end

        Plugins.inherited_instance_variables(self, :@association_dependencies=>:hash_dup, :@association_dependency_reflections=>:hash_dup)
      end

      module InstanceMethods
        # If a restrict check is required for this object, make sure the check and
        # the actual deletion run inside the same database transaction, even if
        # the model does not use transactions by default.
        def destroy(opts=OPTS)
          if Thread.current[:sequel_association_dependencies_check] || !model.association_dependencies_restrict_reachable?
            super
          else
            db.transaction(:server=>this_server){super}
          end
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

        # Check the dependency graph that this destroy will traverse for restrict
        # violations before any dependencies are deleted and before any destroy
        # hooks are called.  Nested destroys of objects already covered by the
        # current check skip the check, since the root object's check already
        # covered the whole dependency graph.
        def _destroy(opts)
          if visited = Thread.current[:sequel_association_dependencies_check]
            check_association_dependencies_restrict(visited) unless visited.key?([model, Array(pk)])
            super
          elsif model.association_dependencies_restrict_reachable?
            begin
              Thread.current[:sequel_association_dependencies_check] = visited = {}
              check_association_dependencies_restrict(visited)
              super
            ensure
              Thread.current[:sequel_association_dependencies_check] = nil
            end
          else
            super
          end
        end

        private

        # Check the dependency graph rooted at this object for restrict violations,
        # raising RestrictViolation if any are found.  Objects in the graph are
        # identified by class and full primary key (all columns for composite
        # primary keys), so shared dependent objects are only checked once and
        # cyclic dependencies terminate.
        def check_association_dependencies_restrict(visited)
          violations = []
          collect_association_dependencies_restrict_violations(visited, [], violations)
          raise RestrictViolation.new(self, violations) unless violations.empty?
        end

        # Recursively collect restrict violations for this object and all objects
        # reachable via :destroy dependencies.  Uses the association datasets (with
        # their real conditions), not any cached associations.
        def collect_association_dependencies_restrict_violations(visited, path, violations)
          return if visited.key?(identity = [model, Array(pk)])
          visited[identity] = true
          refs = model.association_dependency_reflections
          refs[:restrict].each do |r|
            ds = public_send(r[:dataset_method]).limit(RESTRICT_VIOLATION_EXAMPLE_KEYS)
            keys = if pk = r.associated_class.primary_key
              ds.select_map(pk)
            else
              ds.all
            end
            violations << [path + [r[:name]], r, keys] unless keys.empty?
          end
          refs[:destroy].each do |r|
            k = r.associated_class
            next unless k.respond_to?(:association_dependencies_restrict_reachable?) && k.association_dependencies_restrict_reachable?
            public_send(r[:dataset_method]).all.each do |obj|
              obj.send(:collect_association_dependencies_restrict_violations, visited, path + [r[:name]], violations)
            end
          end
        end
      end
    end
  end
end
