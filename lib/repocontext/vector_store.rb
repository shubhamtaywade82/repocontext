# frozen_string_literal: true

require "sqlite3"
require "json"
require "digest"

module RepoContext
  class VectorStore
    DB_FILENAME = "repocontext.db"

    def initialize(repo_root:, logger: Settings.logger)
      @repo_root = repo_root
      @log = logger
      @db_path = File.join(@repo_root, DB_FILENAME)
      init_db
    end

    def find_chunks(path)
      rows = @db.execute("SELECT chunk_index, text, embedding FROM items WHERE path = ? ORDER BY chunk_index ASC", [path])
      rows.map do |row|
        {
          path: path,
          chunk_index: row[0],
          text: row[1],
          embedding: JSON.parse(row[2])
        }
      end
    end

    def upsert(path, mtime, chunks)
      @db.transaction do
        @db.execute("DELETE FROM items WHERE path = ?", [path])
        chunks.each_with_index do |chunk, idx|
          @db.execute(
            "INSERT INTO items (path, mtime, chunk_index, text, embedding) VALUES (?, ?, ?, ?, ?)",
            [path, mtime, idx, chunk[:text], chunk[:embedding].to_json]
          )
        end
      end
    end

    def stored_mtime(path)
      row = @db.get_first_row("SELECT mtime FROM items WHERE path = ? LIMIT 1", [path])
      row ? row[0] : nil
    end

    def count_items
      @db.get_first_value("SELECT COUNT(*) FROM items")
    end

    private

    def init_db
      @db = SQLite3::Database.new(@db_path)

      # Enable WAL mode for better concurrent read/write performance
      @db.execute("PRAGMA journal_mode=WAL;")

      # Optimize for read-heavy workloads
      @db.execute("PRAGMA synchronous=NORMAL;")
      @db.execute("PRAGMA cache_size=-64000;")  # 64MB cache
      @db.execute("PRAGMA temp_store=MEMORY;")

      # Create table
      @db.execute <<-SQL
        CREATE TABLE IF NOT EXISTS items (
          path TEXT,
          mtime INTEGER,
          chunk_index INTEGER,
          text TEXT,
          embedding BLOB
        );
      SQL

      # Create indexes for faster lookups
      @db.execute("CREATE INDEX IF NOT EXISTS idx_path ON items (path);")
      @db.execute("CREATE INDEX IF NOT EXISTS idx_path_chunk ON items (path, chunk_index);")
      @db.execute("CREATE INDEX IF NOT EXISTS idx_path_mtime ON items (path, mtime);")

      # Analyze to optimize query planner
      @db.execute("ANALYZE;")

      @log.debug { "vector store initialized: #{@db_path} (WAL mode)" }
    end
  end
end
