require_relative "lib/ramplitude/version"

Gem::Specification.new do |spec|
  spec.name          = "ramplitude"
  spec.version       = Ramplitude::VERSION
  spec.authors       = ["Julik Tarkhanov"]
  spec.email         = ["me@julik.nl"]

  spec.summary       = "Ruby SDK that posts events to Amplitude, with pluggable buffering."
  spec.description   = "Port of the official Amplitude Python SDK. " \
                       "Supports in-process buffering or out-of-process drains " \
                       "(Redis + Sidekiq/ActiveJob) via a Sink/Uploader split. " \
                       "Not affiliated with Amplitude, Inc."
  spec.homepage      = "https://github.com/julik/ramplitude"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  # Custom property: machine-readable orientation doc for LLM agents wiring
  # this gem into a codebase. https://llmstxt.org/
  spec.metadata["llms_txt_uri"]    = "#{spec.homepage}/blob/main/llms.txt"

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE.txt", "CHANGELOG.md", "llms.txt"]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "minitest", "~> 5.20"
  spec.add_development_dependency "webmock",  "~> 3.23"
  spec.add_development_dependency "rake",     "~> 13.0"
  spec.add_development_dependency "redis",    "~> 5.0"
end
