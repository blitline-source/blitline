require 'timeout'

module Blitline
  class MessageWrapper
    def initialize(raw_msg)
      @raw_msg = raw_msg
      @released = false
    end

    def release_count
      begin
        stats = @raw_msg.stats if @raw_msg
        BlitlineLogger.log "--- #{stats.inspect}"
        return stats["reserves"]
      rescue => ex
        BlitlineLogger.log("Exception BL: Failed to release_count")
        BlitlineLogger.log ex
      end
      return nil
    end

    def release(delay = nil)
      begin
        @released = true
        if @raw_msg
          if delay && delay.to_i > 0
            @raw_msg.release({ :delay => delay })
          else
            @raw_msg.release
          end
          BlitlineLogger.log("release...")
        end
      rescue => ex
        BlitlineLogger.log("Exception BL: Failed to release")
        BlitlineLogger.log ex
      end
    end

    def bury
      begin
        if @raw_msg
          @raw_msg.bury
          BlitlineLogger.log("buried...")
        end
      rescue => ex
        BlitlineLogger.log("Exception BL: Failed to bury")
        BlitlineLogger.log ex
      end
    end

    def released?
      return @released
    end

    def touch
      begin
        if @raw_msg && !@released
          Timeout::timeout(5) do
            @raw_msg.touch
          end
        end
      rescue => ex
        BlitlineLogger.log("Exception BL: Failed to touch")
        BlitlineLogger.log ex
      end
    end

  end
end


