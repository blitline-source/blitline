module Blitline
	class PreProcessor

		DOWNLOAD_FILE_DIR = Dir.tmpdir
		def initialize(application_id, task_id, uploader, image_cache, memcache_wrapper, config, connection_cache)
			@uploader = uploader
			@task_id = task_id
			@image_cache = image_cache
			@application_id = application_id
			@memcache_wrapper = memcache_wrapper
			@config = config
			@connection_cache = connection_cache
		end

		def pre_process(src, pre_process_data)
			BlitlineLogger.log("In preprocess")
			BlitlineLogger.log("In preprocess #{pre_process_data}")

			if (pre_process_data["move_original"]) 
				pre_process_move_original(src, pre_process_data["move_original"])
			elsif (pre_process_data["convert_original"]) # Alias move original
				pre_process_move_original(src, pre_process_data["convert_original"])
			elsif (pre_process_data["resize_gif"])
				pre_process_resize_gif(src, pre_process_data["resize_gif"], :resize)
			elsif (pre_process_data["resize_gif_to_fit"])
				pre_process_resize_gif(src, pre_process_data["resize_gif_to_fit"], :resize_to_fit)
			elsif (pre_process_data["gif_overlay"])
				pre_process_gif_overlay(src, pre_process_data["gif_overlay"])
			elsif (pre_process_data["job"])
				pre_process_job(pre_process_data["job"])
			end
		end

		def pre_process_job(job_data)
			begin
				job = BlitlineJob.new
				job_data["cache_images"] = true
				job.set_params(@application_id, @config, job_data, @task_id, @connection_cache, @memcache_wrapper)
				message_wrapper = Blitline::MessageWrapper.new(nil)
				job.run(message_wrapper, true)
				BlitlineLogger.log("--- PRE_PROCESSING_SAVING--- #{job.image_cache.inspect}")
				@image_cache.merge!(job.image_cache)

			rescue => ex
				BlitlineLogger.log(ex)
				raise "Preprocessing Failed #{ex.message}"
			end
		end

		def pre_process_resize_gif(src, resize_gif_data, type)
			begin
				# Get original
				filepath = nil

				if src.is_a?(Hash) # If src is a hash, handle separately
					src_bucket = src['bucket']
					src_key = src['key']
					filepath = @uploader.download_from_s3(src_key, src_bucket)
				else
					filepath = Blitline::HttpClient.download_file(src)
				end

				# Move original
				s3_destination = resize_gif_data["s3_destination"]
				key = s3_destination["key"]
				bucket = s3_destination["bucket"]
				headers = s3_destination["headers"]

				process_params = resize_gif_data["params"]
				output_path = File.join(DOWNLOAD_FILE_DIR, @task_id + ".gif")
				Blitline::ImageProcessor.resize_gif(type, filepath, output_path, process_params)
				custom_upload(output_path, bucket, key, headers)
			ensure
				puts "Deleting #{filepath}"
				puts "Deleting #{output_path}"
				FileUtils.rm filepath if !filepath.nil? && File.exists?(filepath)
				FileUtils.rm output_path if !output_path.nil? && File.exists?(output_path)
			end
		end

		def pre_process_move_original(src, move_info)
			begin
				# Get original
				filepath = nil

				if src.is_a?(Hash) # If src is a hash, handle separately
					src_bucket = src['bucket']
					src_key = src['key']
					filepath = @uploader.download_from_s3(src_key, src_bucket)
				else
					filepath = Blitline::HttpClient.download_file(src)
				end

				# Move original
				s3_destination = move_info["s3_destination"]
				key = s3_destination["key"]
				bucket = s3_destination["bucket"]
				headers = s3_destination["headers"]
				move_original_pipeline(filepath, bucket, key) do |new_filepath|
					custom_upload(new_filepath, bucket, key, headers)
				end
			ensure
				FileUtils.rm filepath if !filepath.nil? && File.exists?(filepath)
			end
		end

		def move_original_pipeline(filepath, bucket, key)
			file_extension_in = Blitline::HttpClient.derive_file_extension(filepath).to_s.downcase
			file_extension_out = Blitline::HttpClient.derive_file_extension(key).to_s.downcase

			if file_extension_in != file_extension_out
				new_filepath = Blitline::ExternalTools.run_conversion_on_src(filepath, file_extension_in, file_extension_out, @uploader)
			else 
				new_filepath = filepath
			end

			yield(new_filepath)
		end

		def pre_process_gif_overlay(src, overlay_info)
			# Get original
			filepath = nil
			begin
				if src.is_a?(Hash) # If src is a hash, handle separately
					src_bucket = src['bucket']
					src_key = src['key']
					filepath = @uploader.download_from_s3(src_key, src_bucket)
				else
					filepath = Blitline::HttpClient.download_file(src)
				end

				overlay_src = overlay_info["params"]["overlay_src"]
				image_loader = Blitline::ImageLoader.new(@uploader, nil, @image_cache, nil, nil)
				image = image_loader.load_original_image(overlay_src, nil, Blitline::Constants::SRC_TYPE_IMAGE)

				file_extension = Blitline::HttpClient.derive_file_extension(overlay_src)
				file_extension = ".png" if file_extension.blank?

				download_file_directory = DOWNLOAD_FILE_DIR
				tmp_file = File.join(download_file_directory,  Blitline::Utils.suid + file_extension)
				output_path = File.join(download_file_directory,  Blitline::Utils.suid + ".gif")

				image.write(tmp_file)
				composite_params = {}
				::Blitline::ExternalTools.run_gif_composite(composite_params, filepath, tmp_file, output_path)

				# Move original
				s3_destination = overlay_info["s3_destination"]
				key = s3_destination["key"]
				bucket = s3_destination["bucket"]
				headers = s3_destination["headers"]
				custom_upload(output_path, bucket, key, headers)
			ensure
				FileUtils.rm tmp_file if !tmp_file.nil? && File.exists?(tmp_file)
				FileUtils.rm filepath if !filepath.nil? && File.exists?(filepath)
				FileUtils.rm output_path if !output_path.nil? && File.exists?(output_path)
			end
		end


		def custom_upload(file_path, bucket, key, headers)
			begin
				destination_url = @uploader.upload_to_s3(file_path, bucket, key, headers, @config['canonical_id'], @config['public_token'])
				if (destination_url.is_a?(Hash) && destination_url[:error] && destination_url[:error].include?("temporarily unavailable"))
					@message_wrapper.release
				end
			rescue => ex
				BlitlineLogger.log(ex)
			end
			return destination_url
		end
	end
end

