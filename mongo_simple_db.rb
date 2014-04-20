require 'mongo'
require_relative 'constants'

module Blitline
  class MongoSimpleDB
    include Mongo

    PARAMS ={:nil_representation => 'null_string', :logger => Logger.new(STDOUT)}       # interpret Ruby nil as this string value; i.e. use this string in SDB to represent Ruby nils (default is the string 'nil')
    NORMALIZE = ENV["NORMALIZE"].to_f || 1.0

    #BLITLINE_SDB_JOBS_DOMAIN

    def initialize(config, memcache_wrapper = nil)
      @mongo_db_client = MongoClient.new(Blitline::Constants::MONGO_SERVER, Blitline::Constants::MONGO_DB_PORT)
      @mongo_db = @mongo_db_client['blitline_jobs']
      puts Blitline::Constants::MONGO_DB_NAME, Blitline::Constants::MONGO_DB_PASSWORD
      @mongo_db.authenticate(Blitline::Constants::MONGO_DB_NAME, Blitline::Constants::MONGO_DB_PASSWORD)
      @mongo_jobs = @mongo_db['jobs']
      @mongo_atomic_counts = @mongo_db['atomic_counts_capped']
      @mongo_jobs_started = @mongo_db['jobs_started']
      @mongo_users = @mongo_db['b_users']
      @memcache_wrapper = memcache_wrapper
    end

    # Atomic Counter
    def set_atomic_count(suid, count, data)
      BlitlineLogger.log("SET_ATOMIC #{suid} #{count} #{data.to_s}")
      @mongo_atomic_counts.insert({
        :suid => suid,
        :count => count,
        :data => data
      })
    end

    def decrement_atomic_count(suid, amount = 1)
      query = { "suid" => suid }
      update = { "$inc" => { "count" => -amount } }
      begin
        result = @mongo_atomic_counts.find_and_modify({ "query" => query, "update" => update})
      rescue => ex
        BlitlineLogger.log("Failed to find and modify '#{suid}'")
        raise
      end

      return result["count"].to_i - amount
    end

    def increment_atomic_count(suid, amount = 1)
      decrement_atomic_count(suid, -amount)
    end

    def get_atomic_count(suid)
      result = @mongo_atomic_counts.find_one({"suid" => suid})
      if (result && result["count"]) 
        return { "count" => result["count"]} 
      end

      return {}
    end

    def get_atomic_data(suid)
      result = @mongo_atomic_counts.find_one({ "suid" => suid })
      return result["data"]
    end

    # End atomic counter

    def close
      begin
        @mongo_db_client.close if @mongo_db_client
      rescue => ex
        BlitlineLogger.log("Error closing MongoDB Client")
        BlitlineLogger.log(ex)
      end
    end

    def push_user_data_to_mongodb(user_id, data)
      begin
        data["suid"] = user_id
        result =  @mongo_users.update( { "suid" => user_id }, data)
        if (result["updatedExisting"] == false)
          BlitlineLogger.log("Inserting....#{data}")
          @mongo_users.insert(data)
        end
      rescue => ex
        BlitlineLogger.log("Error push_user_data_to_mongodb MongoDB Client")
        BlitlineLogger.log(ex)
      end
    end

    def get_user_data_to_mongodb(user_id)
      @mongo_users.find_one({ "suid" => user_id }) || {}
    end

    def purge_user_memcache
      begin
        if @memcache_wrapper
          @memcache_wrapper.get_all_keys.each do |key|
            user_id = key.gsub("user_", "")
            user_attributes = @memcache_wrapper.get(key)
            if user_attributes
              push_user_data_to_mongodb(user_id, user_attributes)
              @memcache_wrapper.delete(key)
            end
          end
        end
      rescue => ex
        BlitlineLogger.log("Failed to purge_user_memcache")
      end
    end

    def reset_usage(user_id)
      begin
        BlitlineLogger.log("Resetting usage for user #{user_id}")
        result =  get_user_data_to_mongodb(user_id)

        # Get total duration
        if result && result['total_duration']
          user_attributes = {'total_duration' => 0 }
          push_user_data_to_mongodb(user_id, user_attributes)
        end

      rescue => e
        BlitlineLogger.log e
      end
    end

    def set_usage(user_id, seconds, license_count = 0)
      begin
        BlitlineLogger.log("Setting usage for user #{user_id} -> #{seconds.to_s} , #{license_count.to_s}")
        result = get_user_data_to_mongodb(user_id)
        # Set total duration
        if result && result['total_duration']
          user_attributes = {'total_duration' => seconds, 'license_count' => license_count }
        end
        push_user_data_to_mongodb(user_id, user_attributes)
      rescue => e
        BlitlineLogger.log e
      end
    end

    def get_usage(ids)
      license_count = 0
      return_results = {}
      ids.each do |user_id|
        begin
          result = get_user_data_to_mongodb(user_id)
          # Get total duration
          if result && result['total_duration']
            duration = result['total_duration'].to_f
          else
            duration = 0
          end

          if result && result['license_count']
            license_count = result['license_count'].to_f
          else
            license_count = 0
          end

          return_results[user_id] = { "duration" => duration, "license_count" => license_count }
        rescue   => e
          BlitlineLogger.log e
        end
      end

      return_results
    end

    def get_task_info(task_id)
      cached_task = nil
      begin
        cached_task = @memcache_wrapper.get("_task_id:"+task_id)
      rescue => ex
      end

      if cached_task.nil?
        result = @mongo_jobs.find_one(:task_id => task_id)
        unless (result && !result.blank?)
          result = @mongo_jobs_started.find_one(:task_id => task_id)
        end

        if result && result['duration'] && !result['duration'].blank?
          @memcache_wrapper.set("_task_id:"+task_id, result)
        end
        BlitlineLogger.log("Poll result #{result.inspect}")
        return result
      end

      return cached_task
    end

    def get_usage_info(user_id)
      return get_user_data_to_mongodb(user_id)
    end


    def get_last_jobs_for_user(user_id, limit = 50)
      results = []
      aggregate_cursor = @mongo_jobs.find({
        "user_id" => user_id
      }).sort({"start_time" => -1}).limit(limit)

      return [] if aggregate_cursor.count == 0
      return aggregate_cursor.to_a
    end

    def get_jobs_between_hourly(start_time_object, end_time_object)
      results = get_jobs_between(time_as_sortable_string(start_time_object), time_as_sortable_string(end_time_object), {:fields => { "image_results" => 0, "original_meta" => 0, "job_info" => 0}})
      return results
    end

    def get_jobs_between_with_cursor(start_time, end_time, query_select = {})
      @mongo_jobs.find({"start_time" => { "$gt" => time_as_sortable_string(start_time), "$lt" => time_as_sortable_string(end_time) }}, query_select).each do |job|
        yield(job)
      end
    end

    def get_jobs_between(start_time, end_time, query_select = {})
      aggregate = @mongo_jobs.find({"start_time" => { "$gt" => start_time, "$lt" => end_time }}, query_select ).to_a
      return aggregate
    end

    def persist_job_start_info(task_id, job_info, start_time)
      user_id = job_info['user_id']
      application_id = job_info['application_id']

      job_info = ::Yajl::Encoder.encode(job_info)
      if (job_info.length > 1024)
        job_info = job_info.slice!(0,600)
        job_info = "trunc:" + job_info
      end

      job_start_time_string = Blitline::Utils.time_as_sortable_string(start_time)

      job_attributes = {
        'task_id' => task_id,
        'application_id' => application_id,
        'version' => '0',
        'user_id' => user_id,
        'start_time' => job_start_time_string,
        'start' => Time.now,
        'image_results' => "",
      'job_info' => job_info }

      @mongo_jobs_started.insert(job_attributes)
    rescue => ex
      BlitlineLogger.log(ex)
    end

    def persist_job_end_info(task_id, job_info, start_time, end_time, image_results = nil, original_meta = nil, memcache_wrapper = nil)
      license_count = 0
      user_id = job_info['user_id']
      error_value = false
      application_id = job_info['application_id']

      if job_info['imagga_data']
        license_count = job_info['imagga_data'].to_i
      end

      version_2 = job_info && job_info['version']==2

      image_results.each do |image_result|
        error_value = image_result['error']
      end

      deltas = { "q" => job_info.delete("q_delt"), "d" => job_info.delete("d_delt"), "f" => job_info.delete("f_delt"), "pb" => job_info.delete("pb_delt")}
      hostname = job_info.delete("h") || "?"

      if (job_info['postback_error'])
        job_info = job_info['postback_error']
      else
        job_info = ::Yajl::Encoder.encode(job_info)
      end

      if (job_info.length > 4096)
        job_info = job_info.slice(0, 4096)
        job_info = "trunc:" + job_info
      end

      image_info = ::Yajl::Encoder.encode(image_results)


      if (image_info.length > 4096)
        image_info = image_info.slice(0,4090)
        image_info = "trunc:" + image_info
      end

      original_meta = ::Yajl::Encoder.encode(original_meta)
      if (original_meta.length > 1020)
        original_meta = original_meta.slice(0,1018)
        original_meta = "trunc:" + original_meta
      end

      duration = end_time - start_time

      if duration > 600
        BlitlineLogger.log "Duraexception #{duration.inspect}"
        duration = 600
      end

      if duration > 120
        BlitlineLogger.log "Duraexception Minor (2 minute job?) #{duration.inspect} #{task_id}"
        duration = 60
      end

      if NORMALIZE && NORMALIZE > 0.0
        begin # Normalize download and postback for non-aws machines
          BlitlineLogger.log("NORMALIZINGG: #{duration} to #{duration * NORMALIZE}")
          duration = duration * NORMALIZE
        rescue => nex
          BlitlineLogger.log(nex)
        end
      end

      #duration = duration.to_f * 0.95 # Free 5% reduction

      job_start_time_string = Blitline::Utils.time_as_sortable_string(start_time)

      # Track deltas
      job_attributes = {
        'task_id' => task_id,
        'duration' => duration,
        'application_id' => application_id,
        'user_id' => user_id,
        'host' => hostname,
        'job_info' => job_info,
        'start' => start_time,
        'start_time' => job_start_time_string,
        'original_meta' => original_meta,
        'deltas' => deltas,
        'image_count' => image_results ? image_results.length : 0,
        'error' => error_value ? true : false,
        'license_count' => license_count,
        'lco' => 0,
      'image_results' => image_info}


      persist_time = Time.now
      @mongo_jobs.insert(job_attributes)
      persist_time_end = Time.now

      # Update user info
      result = get_user_info(user_id)

      user_total_duration = !(result && result['total_duration']) ? 0 : result['total_duration'].to_f
      original_duration = user_total_duration
      user_total_duration += duration

      # If user crosses free threshold, set usage to make sure user get invalidated if needed
      if original_duration < 7200 and user_total_duration > 7200
        begin
          ::Blitline::HttpClient.post(Blitline::Constants::SET_USAGE_URL, {:key => Blitline::Constants::SDB_CLIENT_KEY, :results =>Yajl::Encoder.encode({ user_id => user_total_duration })})
        rescue => fex
          BlitlineLogger.log "Exception"
          BlitlineLogger.log fex
        end
      end
      result = get_user_info(user_id)
      result['total_duration'] = user_total_duration

      BlitlineLogger.log "Persisting Job End Info...  User ID: #{user_id} User Attributes: #{result} and job_attributes #{job_attributes}"
      @memcache_wrapper.set("user_#{user_id}", result)
    rescue => ex
      BlitlineLogger.log(ex)
    end

    def get_user_info(user_id)
      if @memcache_wrapper
        result = @memcache_wrapper.get("user_#{user_id}")
        if result.nil?
          BlitlineLogger.log "user_#{user_id} not in memcache. Get via sdb"
          result = get_user_data_to_mongodb(user_id)
          @memcache_wrapper.set("user_#{user_id}", result)
        end
        return result
      end

      # Otherwise no memcache
      BlitlineLogger.log "No MEMCACHE, falling back to simpleDB"

      return get_user_data_to_mongodb(user_id)
    end

    def time_as_sortable_string(time, precision = :milli)
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
  end
end
