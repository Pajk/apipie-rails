require 'apipie/static_dispatcher'
require 'yaml'

module Apipie

  class Application
    API_METHODS = %w{GET POST PUT PATCH OPTIONS DELETE}

    # we need engine just for serving static assets
    class Engine < Rails::Engine
      initializer "static assets" do |app|
        app.middleware.use ::Apipie::StaticDispatcher, "#{root}/app/public", Apipie.configuration.doc_base_url
      end
    end

    attr_reader :resource_descriptions

    def initialize
      super
      init_env
    end

    def available_versions
      @resource_descriptions.keys.sort
    end

    def set_resource_id(controller, resource_id)
      @controller_to_resource_id[controller] = resource_id
    end

    def route(controller, method)
      regex = Regexp.new("\\A#{Apipie.configuration.api_base_url[Apipie.configuration.default_version]}")

      @apipie_api_routes ||= Rails.application.routes.routes.select { |x| regex =~ x.path.spec.to_s }

      route_selected = @apipie_api_routes.select{|route|
        controller == route.app.controller(route.defaults) && method.to_s == route.defaults[:action]
      }.first

      path = route_selected.path.spec.to_s.gsub(Apipie.configuration.api_base_url[Apipie.configuration.default_version], '')
      path.gsub!('(.:format)', '')
      path.gsub!('(', '')
      path.gsub!(')', '')

      {path: path, verb: human_verb(route_selected)}
    end

    def human_verb(route)
      verb = API_METHODS.select{|defined_verb| defined_verb =~ route.verb}
      if verb.count != 1
        verb = API_METHODS.select{|defined_verb| defined_verb == route.constraints[:method]}
        if verb.blank?
          raise "Unknow verb #{route.path.spec.to_s}"
        end
      end
      verb.first
    end

    # create new method api description
    def define_method_description(controller, method_name, dsl_data)
      return if ignored?(controller, method_name)
      ret_method_description = nil

      versions = dsl_data[:api_versions] || []
      versions = controller_versions(controller) if versions.empty?

      versions.each do |version|
        resource_name_with_version = "#{version}##{get_resource_name(controller)}"
        resource_description = get_resource_description(resource_name_with_version)

        if resource_description.nil?
          resource_description = define_resource_description(controller, version)
        end

        method_description = Apipie::MethodDescription.new(method_name, resource_description, dsl_data)

        # we create separate method description for each version in
        # case the method belongs to more versions. We return just one
        # becuase the version doesn't matter for the purpose it's used
        # (to wrap the original version with validators)
        ret_method_description ||= method_description
        resource_description.add_method_description(method_description)
      end

      return ret_method_description
    end

    # create new resource api description
    def define_resource_description(controller, version, dsl_data = nil)
      return if ignored?(controller)

      resource_name = get_resource_name(controller)
      resource_description = @resource_descriptions[version][resource_name]
      if resource_description
        # we already defined the description somewhere (probably in
        # some method. Updating just meta data from dsl
        resource_description.update_from_dsl_data(dsl_data) if dsl_data
      else
        resource_description = Apipie::ResourceDescription.new(controller, resource_name, dsl_data, version)

        Apipie.debug("@resource_descriptions[#{version}][#{resource_name}] = #{resource_description}")
        @resource_descriptions[version][resource_name] ||= resource_description
      end

      return resource_description
    end

    # recursively searches what versions has the controller specified in
    # resource_description? It's used to derivate the default value of
    # versions for methods.
    def controller_versions(controller)
      ret = @controller_versions[controller]
      return ret unless ret.empty?
      if controller == ActionController::Base || controller.nil?
        return [Apipie.configuration.default_version]
      else
        return controller_versions(controller.superclass)
      end
    end

    def set_controller_versions(controller, versions)
      @controller_versions[controller] = versions
    end

    def add_param_group(controller, name, &block)
      key = "#{controller.name}##{name}"
      @param_groups[key] = block
    end

    def get_param_group(controller, name)
      key = "#{controller.name}##{name}"
      if @param_groups.has_key?(key)
        return @param_groups[key]
      else
        raise "param group #{key} not defined"
      end
    end

    # get api for given method
    #
    # There are two ways how this method can be used:
    # 1) Specify both parameters
    #   resource_name:
    #       controller class - UsersController
    #       string with resource name (plural) and version - "v1#users"
    #   method_name: name of the method (string or symbol)
    #
    # 2) Specify only first parameter:
    #   resource_name: string containing both resource and method name joined
    #   with '#' symbol.
    #   - "users#create" get default version
    #   - "v2#users#create" get specific version
    def get_method_description(resource_name, method_name = nil)
      if resource_name.is_a?(String)
        crumbs = resource_name.split('#')
        if method_name.nil?
          method_name = crumbs.pop
        end
        resource_name = crumbs.join("#")
        resource_description = get_resource_description(resource_name)
      elsif resource_name.respond_to? :apipie_resource_descriptions
        resource_description = get_resource_description(resource_name)
      else
        raise ArgumentError.new("Resource #{resource_name} does not exists.")
      end
      unless resource_description.nil?
        resource_description.method_description(method_name.to_sym)
      end
    end
    alias :[] :get_method_description

    # options:
    # => "users"
    # => "v2#users"
    # =>  V2::UsersController
    def get_resource_description(resource, version = nil)
      if resource.is_a?(String)
        crumbs = resource.split('#')
        if crumbs.size == 2
          version = crumbs.first
        end
        version ||= Apipie.configuration.default_version
        if @resource_descriptions.has_key?(version)
          return @resource_descriptions[version][crumbs.last]
        end
      else
        resource_name = get_resource_name(resource)
        if version
          resource_name = "#{version}##{resource_name}"
        end

        if resource_name.nil?
          return nil
        end
        resource_description = get_resource_description(resource_name)
        if resource_description && resource_description.controller == resource
          return resource_description
        end
      end
    end

    # get all versions of resource description
    def get_resource_descriptions(resource)
      available_versions.map do |version|
        get_resource_description(resource, version)
      end.compact
    end

    # get all versions of method description
    def get_method_descriptions(resource, method)
      get_resource_descriptions(resource).map do |resource_description|
        resource_description.method_description(method.to_sym)
      end.compact
    end

    def remove_method_description(resource, versions, method_name)
      versions.each do |version|
        resource = get_resource_name(resource)
        if resource_description = get_resource_description("#{version}##{resource}")
          resource_description.remove_method_description(method_name)
        end
      end
    end

    # initialize variables for gathering dsl data
    def init_env
      @resource_descriptions = HashWithIndifferentAccess.new { |h, version| h[version] = {} }
      @controller_to_resource_id = {}
      @param_groups = {}

      # what versions does the controller belong in (specified by resource_description)?
      @controller_versions = Hash.new { |h, controller| h[controller] = [] }
    end

    def recorded_examples
      return @recorded_examples if @recorded_examples
      tape_file = File.join(Rails.root,"doc","apipie_examples.yml")
      if File.exists?(tape_file)
        #if SafeYAML gem is enabled, it will load examples as an array of Hash, instead of hash
        if defined? SafeYAML
          @recorded_examples = YAML.load_file(tape_file, :safe=>false)
        else
          @recorded_examples = YAML.load_file(tape_file)
        end
      else
        @recorded_examples = {}
      end
      @recorded_examples
    end

    def reload_examples
      @recorded_examples = nil
    end

    def to_json(version, resource_name, method_name)

      return unless resource_descriptions.has_key?(version)

      _resources = if resource_name.blank?
        # take just resources which have some methods because
        # we dont want to show eg ApplicationController as resource
        resource_descriptions[version].inject({}) do |result, (k,v)|
          result[k] = v.to_json unless v._methods.blank?
          result
        end
      else
        [@resource_descriptions[version][resource_name].to_json(method_name)]
      end

      url_args = Apipie.configuration.version_in_url ? version : ''

      {
        :docs => {
          :name => Apipie.configuration.app_name,
          :info => Apipie.app_info(version),
          :copyright => Apipie.configuration.copyright,
          :doc_url => Apipie.full_url(url_args),
          :api_url => Apipie.api_base_url(version),
          :resources => _resources
        }
      }
    end

    def api_controllers_paths
      Dir.glob(Apipie.configuration.api_controllers_matcher)
    end

    def reload_documentation
      rails_mark_classes_for_reload
      init_env
      reload_examples

      api_controllers_paths.each do |f|
        load_controller_from_file f
      end
    end

    # Is there a reason to interpret the DSL for this run?
    # with specific setting for some environment there is no reason the dsl
    # should be interpreted (e.g. no validations and doc from cache)
    def active_dsl?
      Apipie.configuration.validate? || ! Apipie.configuration.use_cache? || Apipie.configuration.force_dsl?
    end

    def get_resource_name(klass)
      if klass.class == String
        klass
      elsif @controller_to_resource_id.has_key?(klass)
        @controller_to_resource_id[klass]
      elsif Apipie.configuration.namespaced_resources? && klass.respond_to?(:controller_path)
        return nil if klass == ActionController::Base
        path = klass.controller_path
        path.gsub(version_prefix(klass), "").gsub("/", "-")
      elsif klass.respond_to?(:controller_name)
        return nil if klass == ActionController::Base
        klass.controller_name
      else
        raise "Apipie: Can not resolve resource #{klass} name."
      end
    end

    private

    def version_prefix(klass)
      version = controller_versions(klass).first
      base_url = get_base_url(version)
      return "/" if base_url.nil?
      base_url[1..-1] + "/"
    end

    def get_base_url(version)
      Apipie.configuration.api_base_url[version]
    end

    def get_resource_version(resource_description)
      if resource_description.respond_to? :_version
        resource_description._version
      else
        Apipie.configuration.default_version
      end
    end

    def load_controller_from_file(controller_file)
      controller_class_name = controller_file.gsub(/\A.*\/app\/controllers\//,"").gsub(/\.\w*\Z/,"").camelize
      controller_class_name.constantize
    end

    def ignored?(controller, method = nil)
      ignored = Apipie.configuration.ignored
      return true if ignored.include?(controller.name)
      return true if ignored.include?("#{controller.name}##{method}")
    end

    # Since Rails 3.2, the classes are reloaded only on file change.
    # We need to reload all the controller classes to rebuild the
    # docs, therefore we just force to reload all the code. This
    # happens only when reload_controllers is set to true and only
    # when showing the documentation.
    def rails_mark_classes_for_reload
      ActiveSupport::DescendantsTracker.clear
      ActiveSupport::Dependencies.clear
    end

  end
end
