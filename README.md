[![Gem Version](https://badge.fury.io/rb/hubburu.svg)](https://rubygems.org/gems/hubburu)

# GraphQL Ruby Hubburu Plugin

A tracer for integrating Hubburu with GraphQL Ruby

## Installation

Install by adding it to your Gemfile, then bundling.

```
# Gemfile
gem 'hubburu'
```

## Usage

These are the integration points you need to make to integrate with Hubburu.

1. Add your API key
2. Upload schema SDL to Hubburu
3. Send operation reports to Hubburu

### Adding Your API Key

Register for Hubburu, and you will be able to access your API Key from there. The recommended way is to add it to your environment variables. You can also add it manually to the Hubburu SDK calls.

### Upload schema

Either you can upload your schema on server startup. This is an OK way to do it but not suitable for all environments. If you want to manually send it (such as in a CI/CD pipeline), you can do so like this:

```ruby
namespace :hubburu do
  desc "register new schema version with hubburu"
  task register: :environment do
    api_key = ENV["HUBBURU_API_KEY"]
    environment = ENV["HUBBURU_ENVIRONMENT"] || "default"

    response = Hubburu.push_hubburu_schema(YOUR_SCHEMA, api_key, environment)
    response_code = response.code.to_i

    unless response_code >= 200 && response_code < 300
      raise "Failed to upload schema to Hubburu (status #{response_code})"
    end
  end
end
```

### Send operation reports

This is done by adding the Hubburu tracer to the GraphQL schema.

```ruby
require "hubburu"

class AppSchema < GraphQL::Schema
  ...

  use(Hubburu, request_id_context_key: :request_id)

  use(Hubburu,
    request_id_context_key: :request_id,
    queue_method: ->(path, body, headers) { YOUR_ASYNCHRONOUS_WORKER_METHOD(path, body, headers) })

  ...
end

```

`request_id_context_key` & `queue_method` are optional. Omitting `queue_method` will send Hubburu reports immediate. Adding an asynchronous worker will allow you to configure queueing of the report sendouts. Example of a Sidekiq worker:

```ruby
class HubburuUploadWorker
  include Sidekiq::Worker
  sidekiq_options queue: :low

  def perform(url, body, headers)
    Faraday.post(url, body, headers)
  end
end
```

## Development & Testing

After checking out the repo, run `bin/setup` to install dependencies. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

This plugin is being developed and tested in another repository. You are welcome to send bug reports either as an issue on Github or to [hello@hubburu.com](mailto:hello@hubburu.com).
