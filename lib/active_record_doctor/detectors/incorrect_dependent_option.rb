# frozen_string_literal: true

require "active_record_doctor/detectors/base"

module ActiveRecordDoctor
  module Detectors
    class IncorrectDependentOption < Base # :nodoc:
      @description = "detect associations with incorrect dependent options"
      @config = {
        ignore_models: {
          description: "models whose associations should not be checked",
          global: true
        },
        ignore_associations: {
          description: "associations, written as Model.association, that should not be checked"
        }
      }

      private

      def message(model:, association:, problem:)
        # rubocop:disable Layout/LineLength
        case problem
        when :suggest_destroy
          "use `dependent: :destroy` or similar on #{model}.#{association} - the associated model has callbacks that are currently skipped"
        when :suggest_delete
          "use `dependent: :delete` or similar on #{model}.#{association} - the associated model has no callbacks and can be deleted without loading"
        when :suggest_delete_all
          "use `dependent: :delete_all` or similar on #{model}.#{association} - associated models have no validations and can be deleted in bulk"
        end
        # rubocop:enable Layout/LineLength
      end

      def detect
        models(except: config(:ignore_models)).each do |model|
          next if model.table_name.nil?

          associations = model.reflect_on_all_associations(:has_many) +
                         model.reflect_on_all_associations(:has_one) +
                         model.reflect_on_all_associations(:belongs_to)

          associations.each do |association|
            next if config(:ignore_associations).include?("#{model.name}.#{association.name}")

            if callback_action(association) == :invoke && deletable?(association.klass)
              suggestion =
                case association.macro
                when :has_many then :suggest_delete_all
                when :has_one, :belongs_to then :suggest_delete
                else raise("unsupported association type #{association.macro}")
                end

              problem!(model: model.name, association: association.name, problem: suggestion)
            elsif callback_action(association) == :skip && !deletable?(association.klass)
              problem!(model: model.name, association: association.name, problem: :suggest_destroy)
            end
          end
        end
      end

      def callback_action(reflection)
        case reflection.options[:dependent]
        when :delete, :delete_all then :skip
        when :destroy then :invoke
        end
      end

      def deletable?(model)
        !defines_destroy_callbacks?(model) &&
          dependent_models(model).all? do |dependent_model|
            foreign_key = foreign_key(dependent_model.table_name, model.table_name)

            foreign_key.nil? ||
              foreign_key.on_delete == :nullify || (
                foreign_key.on_delete == :cascade && deletable?(dependent_model)
              )
          end
      end

      def defines_destroy_callbacks?(model)
        # Destroying an associated model involves loading it first hence
        # initialize and find are present. If they are defined on the model
        # being deleted then theoretically we can't use :delete_all. It's a bit
        # of an edge case as they usually are either absent or have no side
        # effects but we're being pedantic -- they could be used for audit
        # trial, for instance, and we don't want to skip that.
        model._initialize_callbacks.present? ||
          model._find_callbacks.present? ||
          model._destroy_callbacks.present? ||
          model._commit_callbacks.present? ||
          model._rollback_callbacks.present?
      end

      def dependent_models(model)
        reflections = model.reflect_on_all_associations(:has_many) +
                      model.reflect_on_all_associations(:has_one)
        reflections.map(&:klass)
      end

      def foreign_key(from_table, to_table)
        connection.foreign_keys(from_table).find do |foreign_key|
          foreign_key.to_table == to_table
        end
      end
    end
  end
end
