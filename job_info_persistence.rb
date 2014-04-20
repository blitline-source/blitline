module Blitline
  class JobInfoPersistence

      def initialize(config, memcache_wrapper)
        begin
          @simple_db = Blitline::MongoSimpleDB.new(config, memcache_wrapper)
        rescue => ex
          puts "Failed to start persistence, this is OK"
        end
        # Stub out your own persistence here
      rescue => ex
        BlitlineLogger.log(ex)
      end

      def persist_job_start_info(task_id, job_info, start_time)
        if @simple_db
          @simple_db.persist_job_start_info(task_id, job_info, start_time) 
        else
          puts "JOB INFO NOT PERSISTED, this is OK"
        end
      rescue => ex
        BlitlineLogger.log(ex)
        # Stub out your own persistence here
      end

      def persist_job_end_info(task_id, job_info, start_time, end_time, image_results = nil, original_meta = nil)
        if @simple_db
          @simple_db.persist_job_end_info(task_id, job_info, start_time, end_time, image_results, original_meta)
        else
          puts "JOB INFO NOT PERSISTED, this is OK"
        end
        # Stub out your own persistence here
      rescue => ex
        BlitlineLogger.log(ex)
      end

      def get_atomic_count(suid)
        @simple_db.get_atomic_count(suid)
      rescue => ex
        BlitlineLogger.log(ex)
      end

      def decrement_atomic_count(suid)
        @simple_db.decrement_atomic_count(suid)
      rescue => ex
        BlitlineLogger.log(ex)
      end

      def get_atomic_data(suid)
        @simple_db.get_atomic_data(suid)
      rescue => ex
        BlitlineLogger.log(ex)
      end

      def set_atomic_count(suid, count, data)
        @simple_db.set_atomic_count(suid, count, data)
      rescue => ex
        BlitlineLogger.log(ex)
      end

      def jobs_completed_cleanup
        if @simple_db
          @simple_db.purge_user_memcache 
          @simple_db.close
        end
      rescue => ex
        BlitlineLogger.log(ex)
      end

  end
end
