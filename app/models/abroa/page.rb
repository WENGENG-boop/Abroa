module Abroa
  # Stable, scoped cursor pagination. Cursors encode only an ordering key,
  # never tenancy or authorization; each page still reapplies the scoped relation.
  class Page
    DEFAULT_LIMIT = 25
    MAX_LIMIT = 100
    CURSOR_PATTERN = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\|[0-9a-f-]{36}\z/

    def self.fetch(scope, limit: nil, cursor: nil)
      size = limit.nil? ? DEFAULT_LIMIT : Integer(limit, exception: false)
      raise ArgumentError, "Invalid page limit" unless size.is_a?(Integer) && size.between?(1, MAX_LIMIT)
      table = scope.klass.table_name
      if cursor.present?
        raise ArgumentError, "Invalid page cursor" unless cursor.is_a?(String) && cursor.bytesize <= 512
        begin
          raw = Base64.urlsafe_decode64(cursor)
          raise ArgumentError unless raw.match?(CURSOR_PATTERN)
          time_string, id = raw.split("|", 2)
          time = Time.iso8601(time_string)
          raise ArgumentError unless UuidFormat.valid?(id)
        rescue ArgumentError, TypeError
          raise ArgumentError, "Invalid page cursor"
        end
        scope = scope.where("(#{table}.created_at > ?) OR (#{table}.created_at = ? AND #{table}.id > ?)", time, time, id)
      end
      rows = scope.order(created_at: :asc, id: :asc).limit(size + 1).to_a
      more = rows.size > size
      rows = rows.take(size)
      next_cursor = if more
        last = rows.last
        Base64.urlsafe_encode64("#{last.created_at.utc.iso8601(6)}|#{last.id}", padding: false)
      end
      { rows: rows, next_cursor: next_cursor }
    end
  end
end
