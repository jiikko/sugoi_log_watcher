module SugoiLogWatcher
  class Request
    attr_accessor :logs, :pid, :queries_count, :aggregation_status, :request_path
    def initialize
      self.logs = []
    end

    def remove_pid_from_logs
      self.pid = logs.first.pid.to_i
      logs.each do |log_line|
        log_line.pid = nil
      end
    end

    def count_sql_calls
      return @queryes_map if @queryes_map
      queryes = logs.find_all { |x| x.is_a?(SugoiLogWatcher::ParsedObject::SQL) }
      queries_count = queryes.count
      queryes_map = {}
      queryes.each do |q|
        queryes_map[q.sql] ||= 0
        queryes_map[q.sql] += 1
      end
      @queryes_map = queryes_map
    end

    def finish
      remove_pid_from_logs
      set_request_path_from_logs
      count_sql_calls
    end

    def set_request_path_from_logs
      log = logs.first
      if log.type != :start
        raise '先頭のログがstart以外なのはおかしい'
      end
      self.request_path = log.request_path
    end

    def started?
      aggregation_status == :start
    end

    def end?
      aggregation_status == :end
    end

    def valid?
      # TODO loop減らせる
      !logs.detect { |l| l.type == :start }.nil? && !logs.detect { |l| l.type == :end }.nil?
    end

    def n1_queries
      threshold = 3
      count_sql_calls.find_all do |sql, count|
        count > threshold
      end
    end
  end

  class Aggregater
    attr_accessor :complated, :buffer
    def initialize
      @buffer = []
      self.complated = []
    end

    def add(line)
      line_parser = SugoiLogWatcher::LineParser.new(line)
      if line_parser.valid?
        buffer << line_parser.parse
      end
    end

    # TODO 集計の間隔によって集計できなかったログを捨てないで次回aggregate時に再利用できるようにする
    # bufferの削除タイミングは、タイムスタンプを見て古いものを削除する
    def aggregate
      chunk = {}
      buffer.each { |object| (chunk[object.pid] ||= []); chunk[object.pid] << object }
      requests = []
      chunk.each do |pid, objects|
        request = Request.new
        requests << request
        objects.each do |object|
          if object.type == :start
            request.aggregation_status = :start
          end
          request.logs.push(object) if request.started?
          # 他のプロセスのendのみが残っている場合、削除する
          if !request.started? && object.type == :end
            request.logs = []
          end
          # ログの探索を終了する
          if request.started? && object.type == :end
            request.finish
            break
          end
        end
      end

      requests.find_all(&:valid?).each do |request|
        complated << request
        request.logs.each { |log| buffer.delete_if { |buff| buff == log } }
      end
    end
  end
end
