module Blitline
  class MemcacheWrapper
    require 'dalli'

    def initialize()
      @key_list = {}
      begin
        @cache = Dalli::Client.new('127.0.0.1:11211')
      rescue => ex
        puts ex.message
        STDOUT.flush
        STDERR.flush
      end
    end

    def set(key, value)
      if @cache
        @key_list[key] = value
        @cache.set(key, value, 3600) # 1hr cache by default
      end
    end

    def get(key)
      result = nil
      if @cache
          result = @cache.get(key)
      end
      return result
    end

    def get_all_keys
      return @key_list.keys
    end

    def delete(key)
      @cache.delete(key)
    end

  end
end
