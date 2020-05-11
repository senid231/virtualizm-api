# frozen_string_literal: true

require_relative 'base_controller'
require_relative 'concerns/user_authentication'

class JsonApiController < BaseController
  rescue_from StandardError, with: :json_api_exception

  class_attribute :renderer, instance_writer: false, default: JSONAPI::Serializable::Renderer.new
  class_attribute :resource_class_name, instance_writer: false
  delegate :resource_class, to: :class

  class << self
    def resource_class
      @resource_class ||= resource_class_name.constantize
    end
  end

  include Concerns::UserAuthentication

  def index
    json_api_verify_env!
    options = json_api_options
    objects = resource_class.find_collection(options)
    body = json_api_response_body(objects, resource_class, options)
    response_json_api status: 200, body: body
  end

  def show
    json_api_verify_env!
    options = json_api_options
    object = resource_class.find_single(path_params[:id], options)
    body = json_api_response_body(object, resource_class, options)
    response_json_api status: 200, body: body
  end

  def create
    json_api_verify_env!
    options = json_api_options
    payload = json_api_body
    data = resource_class::Deserializable.call(payload[:data]&.deep_stringify_keys || {})
    object = resource_class.create(data, options)
    body = json_api_response_body(object, resource_class, options)
    response_json_api status: 201, body: body
  end

  def update
    json_api_verify_env!
    options = json_api_options
    object = resource_class.find_single(path_params[:id], options)
    resource_class.update(object, json_api_data, options)
    body = json_api_response_body(object, resource_class, options)
    response_json_api status: 200, body: body
  end

  def destroy
    json_api_verify_env!
    options = json_api_options
    object = resource_class.find_single(path_params[:id], options)
    resource_class.destroy(object, options)
    response_json_api status: 204
  end

  private

  def authenticate_current_user!
    raise JSONAPI::Errors::UnauthorizedError if current_user.nil?
  end

  def json_api_response_body(object, klass, options)
    expose = { context: options[:context] }
    includes = options[:includes]
    fields = options[:fields] || {}

    body = renderer.render(
        object,
        jsonapi: { version: JSONAPI::Const::SPEC_VERSION },
        class: klass.render_classes,
        expose: expose,
        fields: fields,
        include: includes
    )

    meta = klass.top_level_meta(object.is_a?(Array) ? :collection : :single, options)
    body[:meta] = meta unless meta.nil?

    body
  end

  def json_api_context
    { request: request }
  end

  def json_api_options
    {
        context: json_api_context,
        filters: (request.params['filter'] || {}).symbolize_keys,
        includes: request.params['include'].to_s.split(','),
        fields: (request.params['fields'] || {}).transform_values { |v| v.split(',') }.symbolize_keys
    }
    # TODO: verify options
  end

  def json_api_data
    hash = JSON.parse(request.body.read, symbolize_names: true)
    data = hash[:data][:attributes]
    (hash[:data][:relationships] || {}).each do |name, val|
      data[name] = val[:data]
    end
    data
  end

  def json_api_exception(error)
    unless error.is_a?(JSONAPI::Errors::Error)
      log_error(error)
      error = JSONAPI::Errors::ServerError.new
    end
    body = renderer.render_errors(
        [error],
        jsonapi: { version: JSONAPI::Const::SPEC_VERSION },
        class: error.render_classes,
        expose: error.render_expose
    )
    response_json_api(status: error.status, body: body)
  end

  def response_json_api(status: 200, headers: {}, body: nil)
    headers = headers.merge(Rack::CONTENT_TYPE => JSONAPI::Const::MIME_TYPE)
    body = body.to_json if body.is_a?(Hash)
    [status, headers, [body]]
  end

  def json_api_verify_env!
    accepts = env['HTTP_ACCEPT'].to_s.split(';').first&.split(',') || []
    raise JSONAPI::Errors::BadRequest, 'Wrong Accept header' unless accepts.include?(JSONAPI::Const::MIME_TYPE)

    return if !request.post? && !request.put? && !request.patch?

    content_type = request.content_type
    raise JSONAPI::Errors::BadRequest, 'Wrong Content-Type header' if content_type != JSONAPI::Const::MIME_TYPE
  end

  def json_api_body
    JSON.parse(request.body.read, symbolize_names: true)
  end
end
