# frozen_string_literal: true

module RepoContext
  # Single responsibility: discover candidate file paths in the repo and (optionally) use LLM to pick a subset.
  class DiscoveryPathSelector
    DISCOVERY_SCHEMA = {
      "type" => "object",
      "required" => ["paths"],
      "properties" => { "paths" => { "type" => "array", "items" => { "type" => "string" } } }
    }.freeze

    def initialize(repo_root:, client:, model:, logger: Settings.logger)
      @repo_root = repo_root
      @client = client
      @model = model
      @log = logger
    end

    def candidate_paths
      scan_repo_paths
    end

    def pick_paths(question, paths)
      return [] if paths.empty?

      prompt = build_pick_prompt(question, paths)
      response = @client.generate(prompt: prompt, schema: DISCOVERY_SCHEMA, model: @model)
      chosen = Array(response["paths"]).first(Settings::DISCOVERY_PATHS_MAX)
      @log.info { "discovery: picked #{chosen.size} path(s): #{chosen.join(', ')}" }
      chosen
    rescue Ollama::Error => e
      @log.warn { "discovery pick_paths failed: #{e.message}" }
      []
    end

    private

    def scan_repo_paths
      dirs = ["."]
      %w[app lib config docs].each { |d| dirs << d if Dir.exist?(File.join(@repo_root, d)) }
      paths = []
      dirs.each do |dir|
        full = dir == "." ? @repo_root : File.join(@repo_root, dir)
        next unless Dir.exist?(full)

        pattern = dir == "." ? "*.{rb,md,json}" : "*/*.{rb,md,json}"
        Dir.glob(File.join(full, pattern)).each do |p|
          paths << p.delete_prefix("#{@repo_root}/") if File.file?(p)
          break if paths.size >= Settings::CANDIDATE_PATHS_MAX
        end
        break if paths.size >= Settings::CANDIDATE_PATHS_MAX
      end
      paths.uniq.first(Settings::CANDIDATE_PATHS_MAX)
    end

    def build_pick_prompt(question, paths)
      <<~PROMPT
        User question about the codebase: #{question}

        List of file paths in the repo (one per line):
        #{paths.first(60).join("\n")}

        Return a JSON object with one key "paths": an array of up to #{Settings::DISCOVERY_PATHS_MAX} paths from the list above that are most relevant to answer the question. Use exact path strings from the list.
      PROMPT
    end
  end
end
