# frozen_string_literal: true

require "agent_runtime"
require "ollama_client"
require "mcp"
require "json"
require "pty"
require_relative "ollama_client_factory"

module RepoContext
  # An unbuffered I/O transport for MCP CLI tools using a Pseudo-Terminal.
  class CLIStdioTransport
    def initialize(*cmd)
      @out, @in, @pid = PTY.spawn(*cmd)
      @boot_complete = false

      # We must swallow the initial boot logs to sync up the json streams!
      Thread.new do
        loop do
          line = @out.gets
          break if line.nil? || line.include?("Proxy established successfully")
        rescue Errno::EIO
          break
        end
        @boot_complete = true
      end.join(5) # Give it 5s to boot
    end

    def send_request(request:)
      escaped_json = request.to_json
      puts "[send_request] OUT: #{escaped_json}" if ENV["DEBUG_MCP"]
      @in.puts(escaped_json)

      # Notifications do not receive responses
      return nil if request[:method]&.start_with?("notifications/")

      response = read_response
      puts "[send_request] IN: #{response.to_json}" if ENV["DEBUG_MCP"]
      response
    rescue StandardError => e
      warn "Failed to communicate with remote MCP server: #{e.message}"
      raise e
    end

    def close
      @in&.close
      @out&.close
      Process.kill("KILL", @pid) if @pid
    rescue Errno::ESRCH, Errno::EPIPE
      # Already closed or gone
    end

    private

    def read_response
      loop do
        line = @out.gets
        raise "No response from MCP server" if line.nil?
        next if line.strip.empty?

        # PTY sometimes echos the input command back to stdout, filter it out
        next if line.include?("jsonrpc") && !line.start_with?("{")
        next unless line.start_with?("{")

        result = parse_json_rpc(line)
        return result if result
      end
    rescue Errno::EIO
      warn "MCP Server exited prematurely."
      raise "No response from MCP server"
    end

    def parse_json_rpc(line)
      parsed = JSON.parse(line)
      # Make sure this isn't just PTY echoing our STDIN back to us (must have result/error)
      return parsed if parsed.key?("result") || parsed.key?("error")

      nil
    rescue JSON::ParserError
      nil
    end
  end

  class DiscoveryService
    REPOSITORIES = [
      "https://gitmcp.io/shubhamtaywade82/dhanhq-client",
      "https://gitmcp.io/shubhamtaywade82/algo_trading_api",
      "https://gitmcp.io/shubhamtaywade82/algo_scalper_api"
    ].freeze

    def initialize(client: nil, model: Settings::OLLAMA_MODEL, logger: Settings.logger)
      @client = client || OllamaClientFactory.build(
        model: model,
        temperature: Settings::OLLAMA_TEMPERATURE.to_f,
        timeout: Settings::OLLAMA_TIMEOUT
      )
      @model_name = model
      @log = logger
      @tools = AgentRuntime::ToolRegistry.new
      @transports = []
    end

    def run(query, repo_urls: REPOSITORIES, &on_event)
      setup_mcp_connections(repo_urls, &on_event)

      remote_tool_names = @tools.instance_variable_get(:@tools).keys
      @log.info { "Registered #{remote_tool_names.size} remote tools" }
      on_event&.call(:registered_tools, count: remote_tool_names.size, tools: remote_tool_names)

      agent = build_agent(remote_tool_names)

      @log.info { "Running discovery query: '#{query}'" }
      on_event&.call(:query_start, query: query)

      # We can't easily stream AgentRuntime::AgentFSM.run yet, but we can emit when it's finished
      result = agent.run(initial_input: query)

      on_event&.call(:query_done, result: result[:final_message] || result.inspect)
      result[:final_message] || result.inspect
    ensure
      cleanup
    end

    private

    def setup_mcp_connections(repo_urls, &on_event)
      @log.info { "Starting npx mcp-remote bridges..." }
      on_event&.call(:status, message: "Connecting to remote repositories...")

      repo_urls.each do |repo_url|
        repo_name = repo_url.split("/").last
        @log.info { "Connecting to repository: #{repo_name}..." }
        on_event&.call(:connecting, repo: repo_name, url: repo_url)

        begin
          transport = CLIStdioTransport.new("npx", "-y", "mcp-remote", repo_url)
          @transports << transport

          mcp_client = MCP::Client.new(transport: transport)

          transport.send_request(request: {
            jsonrpc: "2.0",
            id: "init-#{repo_name}",
            method: "initialize",
            params: {
              protocolVersion: "2024-11-05",
              capabilities: {},
              clientInfo: { name: "AgentRuntime", version: "1.0.0" }
            }
          })

          transport.send_request(request: {
            jsonrpc: "2.0",
            method: "notifications/initialized"
          })

          registered = @tools.register_mcp_client(mcp_client)
          @log.info { "✅ Handshook #{repo_name} and registered #{registered.size} tools." }
          on_event&.call(:connected, repo: repo_name, tool_count: registered.size)
        rescue StandardError => e
          @log.error { "❌ Failed to connect to #{repo_name}: #{e.message}" }
          on_event&.call(:error, repo: repo_name, message: e.message)
        end
      end
    end

    def build_agent(remote_tool_names)
      planner_schema = {
        "type" => "object",
        "required" => %w[action params confidence],
        "properties" => {
          "action" => {
            "type" => "string",
            "enum" => remote_tool_names + ["finish"],
            "description" => "The exact tool call to make, or 'finish' to stop executing."
          },
          "params" => {
            "type" => "object",
            "additionalProperties" => true,
            "description" => "The parameters to pass into the tool."
          },
          "confidence" => {
            "type" => "number",
            "description" => "A probability between 0 and 1 estimating success."
          }
        }
      }

      AgentRuntime::AgentFSM.new(
        planner: AgentRuntime::Planner.new(
          client: @client,
          model: @model_name,
          schema: planner_schema,
          prompt_builder: lambda { |input:, state:|
            @log.info { "Agent Planning for goal: #{input}" }
            <<~PROMPT
              GOAL: #{input}

              You are an advanced agent with access to multiple remote GitHub repositories via specialized tools.

              RULES:
              1. Use 'fetch_*_documentation' tools FIRST to understand the repo.
              2. Output ONLY the JSON action payload described by the schema.
              3. No conversational text or "Thinking" blocks allowed in output.

              EXAMPLE ACTION:
              {"action": "fetch_dhanhq_client_documentation", "params": {}, "confidence": 1.0}

              AVAILABLE TOOLS: #{remote_tool_names.join(", ")}

              CURRENT STATE: #{state.to_json}
            PROMPT
          }
        ),
        tool_registry: @tools,
        executor: AgentRuntime::Executor.new(tool_registry: @tools),
        policy: self.class::MCPPolicy.new,
        state: AgentRuntime::State.new
      )
    end

    def cleanup
      @transports.each(&:close)
    end

    class MCPPolicy < AgentRuntime::Policy
      def validate!(decision, _state = nil)
        raise AgentRuntime::PolicyViolation, "Missing action" unless decision.action
      end

      def converged?(state)
        state.snapshot[:final_message] || false
      end
    end
  end
end
