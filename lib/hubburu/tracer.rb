# frozen_string_literal: true

module Hubburu
  class Tracer
    MAX_ERROR_BYTES = 1_000

    def initialize(
      schema,
      api_key: Hubburu.api_key,
      environment: Hubburu.environment,
      push_schema_on_startup: false,
      request_id_context_key: nil,
      should_send: nil
    )
      @api_key = api_key
      @environment = environment
      @request_id_context_key = request_id_context_key
      @schema_sha = sha256(GraphQL::Schema::Printer.print_schema(schema))
      @should_send = should_send
      @headers = {
        "X-Api-Key" => @api_key,
        "Content-Type" => "application/json"
      }

      @query_signature = query_signature || proc do |query|
        query.query_string
      end

      Hubburu.push_hubburu_schema(schema, @api_key, @environment) if push_schema_on_startup
    end

    attr_reader :query_signature

    def trace(key, data)
      case key
      when "validate"
        result = yield

        query = data.fetch(:query)
        query.context.namespace(self.class).merge!(
          requestId: query.context[@request_id_context_key],
          operationName: query.operation_name,
          gzippedOperationBody: Hubburu.gzip(query_signature.call(query)),
          schemaHash: @schema_sha,
          errors: result.to_h.fetch(:errors).map { |e| { message: e.message } },
          environment: @environment,
          start_time_nanos: nanos_now,
          clientName: query.context[:client_name],
          clientVersion: query.context[:client_version],
          meta: {}
        )
      when "execute_query"
        begin
          result = yield
        rescue StandardError => e
          query = data.fetch(:query)
          report = query.context.namespace(self.class)
          begin
            report[:errors].push(message: e.respond_to?(:message) ? "[#{e.class.name}] #{e.message}" : e.class.name,
                                 details: e.backtrace.take(10).join('\n\n'))
          rescue StandardError => e
            warn "HUBBURU_FORMAT_ERROR #{e}"
          end
          send(report, query)
          raise e
        end
      when "execute_query_lazy"
        begin
          result = yield
        rescue StandardError => e
          query = data.fetch(:query)
          report = query.context.namespace(self.class)
          begin
            report[:errors].push(message: e.respond_to?(:message) ? "[#{e.class.name}] #{e.message}" : e.class.name,
                                 details: e.backtrace.take(10).join('\n\n'))
          rescue StandardError => e
            warn "HUBBURU_FORMAT_ERROR #{e}"
          end
          send(report, query)
          raise e
        end

        query = data.fetch(:query)
        report = query.context.namespace(self.class)
        if query.static_errors.present?
          begin
            query.static_errors.each do |static_error|
              report[:errors].push(message: static_error.message,
                                   details: static_error.respond_to?(:path) ? static_error.path : nil)
            end
          rescue StandardError => e
            warn "HUBBURU_FORMAT_ERROR #{e}"
          end
        end
        send(report, query)
      else
        result = yield
      end

      result
    end

    def send(report, query)
      begin
        return if @should_send && !@should_send.call(report)
      rescue StandardError => e
        warn "hubburu should_send lambda raised error #{e}"
      end

      post_processing_start = nanos_now

      if report[:start_time_nanos]
        report[:totalMs] = to_report_ms(nanos_now - report[:start_time_nanos])
        report.delete(:start_time_nanos)
      end
      report[:createdAt] = Time.now.utc.iso8601
      errors = report[:errors]
      if errors.empty?
        report.delete(:errors)
      else
        report[:errors] = Hubburu.gzip(errors.to_json)
      end

      errors_too_large = !(report[:errors] && report[:errors].bytesize > MAX_ERROR_BYTES).nil?

      if errors_too_large
        report[:errors] = Hubburu.gzip(errors.take(5).to_json)
        report[:meta][:errorsTooLarge] = errors.size
      end

      report[:enums] = {}
      context = query.context
      schema = context.schema
      begin
        query.selected_operation.variables.each do |ast_variable|
          variable_name = ast_variable.name
          variable_type = schema.type_from_ast(ast_variable.type, context: context)
          provided_value = query.provided_variables[variable_name]

          case variable_type.kind.name
          when "NON_NULL", "LIST", "INPUT_OBJECT"
            trace_type_enums(variable_type, provided_value, report[:enums])
          when "ENUM"
            type_name = variable_type.to_type_signature

            report[:enums][type_name] ||= []
            report[:enums][type_name] |= [provided_value]
          end
        end
      rescue StandardError => e
        warn "HUBBURU_ENUM_ERROR #{e}"
      end

      report[:meta][:postProcessingTime] = to_report_ms(nanos_now - post_processing_start)

      trace = report.to_json

      Hubburu.send("/operation", trace, @headers) if @api_key
    rescue StandardError => e
      warn "HUBBURU_SEND_ERROR #{e}"
    end

    private

    def trace_type_enums(type, provided_value, enums)
      case type.kind.name
      when "NON_NULL"
        trace_type_enums(type.of_type, provided_value, enums)
      when "LIST"
        provided_value.each do |value|
          trace_type_enums(type.of_type, value, enums)
        end
      when "INPUT_OBJECT"
        type.arguments.each do |argument_name, argument_value|
          next unless provided_value[argument_name]

          trace_type_enums(argument_value.type, provided_value[argument_name], enums)
        end
      when "ENUM"
        type_name = type.to_type_signature

        enums[type_name] ||= []
        enums[type_name] |= [provided_value]
      end
    end

    def to_report_ms(nanos)
      (nanos / 10_000) / 100.0
    end

    def nanos_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    end

    def sha256(data)
      Digest::SHA256.hexdigest(data)
    end
  end
end
