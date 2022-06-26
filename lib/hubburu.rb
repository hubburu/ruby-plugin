# frozen_string_literal: true

require_relative "hubburu/tracer"
require_relative "hubburu/version"

module Hubburu
  def self.use(schema, options = {})
    @queue_method = options[:queue_method]
    options.delete(:queue_method)

    schema.tracer(Hubburu::Tracer.new(schema, **options))
  end

  def self.push_hubburu_schema(schema, api_key = Hubburu.api_key, environment = Hubburu.environment)
    unless api_key
      warn "HUBBURU_SEND_ERROR missing api_key"
      return
    end

    Hubburu.send(
      "/schema",
      {
        sdl: Hubburu.gzip(GraphQL::Schema::Printer.print_schema(schema)),
        environment: environment
      }.to_json,
      {
        "X-Api-Key" => api_key,
        "Content-Type" => "application/json"
      }
    )
  end

  def self.api_key
    @api_key ||= ENV["HUBBURU_API_KEY"]
  end

  def self.report_url
    @report_url ||= ENV["HUBBURU_REPORT_URL"] || "https://report.hubburu.com"
  end

  def self.environment
    @environment ||= ENV["HUBBURU_ENVIRONMENT"] || "default"
  end

  def self.gzip(data)
    output = StringIO.new
    gz = Zlib::GzipWriter.new(output)
    gz.write(data)
    gz.close
    Base64.encode64(output.string)
  end

  def self.send(path, body, headers)
    if @queue_method
      @queue_method.call(
        Hubburu.report_url + path,
        body,
        headers
      )
    else
      Net::HTTP.post(
        URI(Hubburu.report_url + path),
        body,
        headers
      )
    end
  end
end
