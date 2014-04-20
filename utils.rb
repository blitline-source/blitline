unless defined?(BlitlineLogger)
  require 'blitline/job/blitline_logger'
end

module Blitline
  class Utils
    require 'uri'

    MEM_USED_LIMIT = 0.70
    LOAD_AVERAGE_LIMIT = 4.0

    def self.date_time_now_as_sortable_string
      Time.now.strftime("%Y%m%d%H")
    end

    def self.time_as_sortable_string(time, precision = :milli)
      format = "%Y%m%d%H%M%S%L"

      case precision
        when :milli
          format = "%Y%m%d%H%M%S%L"
        when :second
          format = "%Y%m%d%H%M%S"
        when :minute
          format = "%Y%m%d%H%M"
        when :hour
          format = "%Y%m%d%H"
        when :day
          format = "%Y%m%d"
        else
          puts "Here :#{precision}:"
      end

      time.utc.strftime(format)
    end

    def self.suid(length=16)
      prefix = rand(10).to_s
      random_string = prefix + ::SecureRandom.urlsafe_base64(length)
    end

    def self.sexagesimal_to_decimal(degrees_minutes_seconds, ref)
      degrees, minutes, seconds = degrees_minutes_seconds.gsub(" ","").split(",")
      # Using rational to keep maximum precision until conversion to float
      degrees = (Rational(*(degrees.split('/').map( &:to_i )))).to_f
      minutes = (Rational(*(minutes.split('/').map( &:to_i )))).to_f
      seconds = (Rational(*(seconds.split('/').map( &:to_i )))).to_f

      decimal_degrees = degrees.to_f + (minutes / 60.0) + (seconds / 3600.0)
      decimal_degrees = -decimal_degrees if (ref.upcase=="W")
      decimal_degrees = -decimal_degrees if (ref.upcase=="S")
      return decimal_degrees
      rescue => ex
        BlitlineLogger.log(ex)
    end

    def self.attempt_to_gracefully_handle_url(url)
      original_url = url
      better_url = nil

      better_url = URI.parse(url) rescue nil
      return better_url if better_url

      partially_encoded_url = url
      partially_encoded_url = partially_encoded_url.gsub('[', '%5B')
      partially_encoded_url = partially_encoded_url.gsub(']', '%5D')

      better_url = URI.parse(partially_encoded_url) rescue nil
      return better_url if better_url

      url = URI.encode(url)
      url = url.gsub('[', '%5B')
      url = url.gsub(']', '%5D')

      better_url = URI.parse(url) rescue nil
      return better_url if better_url

      original_url # Well... we tried
    end

    def self.has_mem_available?
      begin
        mem = `free | grep buffers\/cache`
        row_items = mem.split(" ")
        used, free = row_items.last(2)
        used = used.to_i
        free = free.to_i
        return true if used + free || used==0 || free==0

        total = used + free
        over_limit = used.to_f / total.to_f > MEM_USED_LIMIT
        BlitlineLogger.log "OVERLIMIT #{used.to_f} #{total.to_f}" if over_limit
        return false if over_limit
      rescue => ex
        BlitlineLogger.log "has_mem_available? #{ex.message}"
        return false
      end
      return true
    end

    def self.has_cpu_available?
      begin
        load_average = `uptime| awk '{print $10}'`
        if load_average.include?("average:")
          load_average = `uptime| awk '{print $11}'`
        end

        load_average = load_average.to_s.gsub(/\s+/, "")
        if load_average.to_f > LOAD_AVERAGE_LIMIT
          return false
        end
      rescue => ex
        BlitlineLogger.log "has_cpu_available? #{ex.message}"
      end
      return true
    end

    def self.has_resources_available?
      return has_mem_available? && has_cpu_available?
    end

  end
end
