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
      picked_paths = Array(response["paths"]).first(Settings::DISCOVERY_PATHS_MAX)
      @log.info { "discovery: picked #{picked_paths.size} path(s): #{picked_paths.join(', ')}" }
      picked_paths
    rescue Ollama::Error => e
      @log.warn { "discovery pick_paths failed: #{e.message}" }
      []
    end

    private

    PATHS_IN_PROMPT_LIMIT = 60

    def scan_repo_paths
      search_dirs = ["."]
      %w[app lib config docs].each { |d| search_dirs << d if Dir.exist?(File.join(@repo_root, d)) }

      paths = []
      search_dirs.each do |dir|
        dir_path = dir == "." ? @repo_root : File.join(@repo_root, dir)
        next unless Dir.exist?(dir_path)

        glob_pattern = dir == "." ? "*.{rb,md,json}" : "*/*.{rb,md,json}"
        collect_paths_from_dir(dir_path, glob_pattern, paths)
        break if paths.size >= Settings::CANDIDATE_PATHS_MAX
      end
      paths.uniq.first(Settings::CANDIDATE_PATHS_MAX)
    end

    def collect_paths_from_dir(dir_path, glob_pattern, paths)
      Dir.glob(File.join(dir_path, glob_pattern)).each do |abs_path|
        paths << abs_path.delete_prefix("#{@repo_root}/") if File.file?(abs_path)
        return if paths.size >= Settings::CANDIDATE_PATHS_MAX
      end
    end

    def build_pick_prompt(question, paths)
      path_list = paths.first([paths.size, PATHS_IN_PROMPT_LIMIT].min).join("\n")
      <<~PROMPT
        User question about the codebase: #{question}

        List of file paths in the repo (one per line):
        #{path_list}

        Return a JSON object with one key "paths": an array of up to #{Settings::DISCOVERY_PATHS_MAX} paths from the list above that are most relevant to answer the question. Use exact path strings from the list.
      PROMPT
    end
  end
end
