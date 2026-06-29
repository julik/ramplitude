# frozen_string_literal: true

module Ramplitude
  class Plan
    attr_accessor :branch, :source, :version, :version_id

    def initialize(branch: nil, source: nil, version: nil, version_id: nil)
      @branch     = branch
      @source     = source
      @version    = version
      @version_id = version_id
    end

    def to_h
      h = {}
      h["branch"]    = @branch     if @branch
      h["source"]    = @source     if @source
      h["version"]   = @version    if @version
      h["versionId"] = @version_id if @version_id
      h
    end
  end

  class IngestionMetadata
    attr_accessor :source_name, :source_version

    def initialize(source_name: nil, source_version: nil)
      @source_name    = source_name
      @source_version = source_version
    end

    def to_h
      h = {}
      h["source_name"]    = @source_name    if @source_name
      h["source_version"] = @source_version if @source_version
      h
    end
  end
end
