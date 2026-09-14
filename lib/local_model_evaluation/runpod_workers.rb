# frozen_string_literal: true

module LocalModelEvaluation
  module RunpodWorkers
    MIN_WORKERS = 1
    MAX_WORKERS = 16

    class Error < StandardError; end

    module_function

    def validate_count(value)
      count = Integer(value)
      unless count.between?(MIN_WORKERS, MAX_WORKERS)
        raise Error, "workers must be between #{MIN_WORKERS} and #{MAX_WORKERS}"
      end

      count
    rescue ArgumentError, TypeError
      raise Error, "workers must be an integer between #{MIN_WORKERS} and #{MAX_WORKERS}"
    end

    def validate_index(value)
      index = Integer(value)
      unless index.between?(MIN_WORKERS, MAX_WORKERS)
        raise Error, "worker index must be between #{MIN_WORKERS} and #{MAX_WORKERS}"
      end

      index
    rescue ArgumentError, TypeError
      raise Error, "worker index must be an integer between #{MIN_WORKERS} and #{MAX_WORKERS}"
    end

    def parse_selector(value)
      tokens = value.to_s.split(",").map(&:strip).reject(&:empty?)
      raise Error, "workers requires a list such as 1-12 or 1,6,12" if tokens.empty?

      indices = tokens.flat_map do |token|
        if (match = token.match(/\A(\d+)-(\d+)\z/))
          first = validate_index(match[1])
          last = validate_index(match[2])
          raise Error, "descending worker range: #{token}" if first > last

          (first..last).to_a
        elsif token.match?(/\A\d+\z/)
          validate_index(token)
        else
          raise Error, "invalid worker selector: #{token.inspect}"
        end
      end

      indices.uniq.sort
    end
  end
end
