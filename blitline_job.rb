require 'fileutils'
require 'RMagick'
require 'timeout'
require 'tmpdir'
require 'securerandom'

require 'right_http_connection'
require 'right_aws'
require 'yajl'
require 'oj'
require 'httparty'
require 'awesome_print'
require 'blitline/job/image_loader'
require 'blitline/job/pre_processor'
require 'blitline/job/blitline_logger'
require 'blitline/job/http_client'
require 'blitline/job/external_tools' # Must be before image_processor
require 'blitline/job/image_processor'
require 'blitline/job/uploader'
require 'blitline/job/message_wrapper'
require 'blitline/job/utils'
require 'blitline/job/mongo_simple_db'
require 'blitline/job/job_info_persistence'
require 'blitline/job/constants'
require 'blitline/job/imagga/imagga_wrapper'
require 'blitline/job/alt_job'
require 'blitline/job/job_group_container'
require 'blitline/job/zipper'

class BlitlineJob
	# Funkify

	OUTPUT_TYPES = ["postback", "temp_url"]
	DOWNLOAD_FILE_DIR = Dir.tmpdir
	IMAGE_SIZE_MAX = 500000000
	RightAws::RightAWSParser.xml_lib = 'libxml'

	attr_accessor :image_cache

	def initialize
		BlitlineLogger.log("Init")
		Blitline::ExternalTools.create_pdf_info_shell_file
		Blitline::ExternalTools.create_convert_info_shell_file
		Blitline::ExternalTools.create_pdf_burst_shell_file
		Blitline::ExternalTools.create_auto_enhance_shell_file
		Blitline::ExternalTools.copy_profiles

		@image_cache = {}
	end

	def set_params(application_id, config, data, task_id, connection_cache, memcache_wrapper)
		@start_time = Time.now
		@application_id = application_id
		@config = config
		@data = data
		@image_cache.clear
		@connection_cache = connection_cache
		@task_id = nil || task_id
		@job_info_persistence = Blitline::JobInfoPersistence.new(@config, memcache_wrapper) unless defined? @job_info_persistence
		@uploader = Blitline::Uploader.new(@connection_cache) unless defined? @uploader
	end

	def jobs_completed_cleanup
		if @job_info_persistence
			@job_info_persistence.jobs_completed_cleanup
		end
	end

	def run(msg_wrapper, is_pre_process = false)
		@message_wrapper = msg_wrapper#
		results = []
		original_image_metadata = nil

		begin
			validate_initial_data
			task_id = @task_id
			@job_info_persistence.persist_job_start_info(task_id, @data, @start_time) unless @data['is_preprocessing']
			type = @data['type']
			src_type = @data['src_type']
			# Handle Preprocessing
			if @data['pre_process']
				pre_processor = Blitline::PreProcessor.new(@application_id, @task_id, @uploader, @image_cache, @memcache_wrapper, @config, @connection_cache)
				if @data['pre_process'].is_a?(Hash)
					pre_processor.pre_process(@data['src'], @data['pre_process'])
				elsif @data['pre_process'].is_a?(Array)
					@data['pre_process'].each do |pre_process_function|
						pre_processor.pre_process(@data['src'], pre_process_function)
					end
				end
			end

			BlitlineLogger.log("P_#{@config['app_priority']}")
			BlitlineLogger.log("Loading image")
			image_or_images = nil
			@message_wrapper.touch
			if src_type == Blitline::Constants::SRC_TYPE_ZIP
				zip_executor = Blitline::Zipper.new(@data, @uploader, @config)
				results = results + zip_executor.execute
				d_delt = zip_executor.load_delta
				f_delt = zip_executor.function_delta
			elsif src_type == Blitline::Constants::SRC_TYPE_GIF
				alt_job = Blitline::AltJob.new
				alt_job.handle_gif_types(@data, @uploader, results, @config, @image_cache)
			elsif src_type == Blitline::Constants::SRC_TYPE_BURST_PDF
				job_group_container = Blitline::JobGroupContainer.new(@data['application_id'], @config, @data, @uploader, @job_info_persistence, @data["group_completion_job_id"])
				job_group_container.run_job_group(Blitline::Constants::SRC_TYPE_BURST_PDF)
			elsif src_type == Blitline::Constants::SRC_TYPE_PREPROCESS_ONLY
				results = { "pre_process_successful" => true }
				# Nothing much to do here now
			else
				image_loader = Blitline::ImageLoader.new(@uploader, @message_wrapper, @image_cache, @data, results)
				d_delt = get_delta do
					image_or_images = image_loader.load_original_image(@data['src'], @data['src_data'], @data['src_type'])
					if @data["extended_metadata"].to_s == "true" && @data["passthrough_metadata"]
						original_image_metadata = @data.delete("passthrough_metadata")
					end

				end
				@message_wrapper.touch

				f_delt = get_delta do
					if src_type == Blitline::Constants::SRC_TYPE_MULTI_PAGE || (src_type.is_a?(Hash) &&  src_type['name'] == Blitline::Constants::SRC_TYPE_MULTI_PAGE)# image_or_images is array
						handle_multipage_source(src_type, image_or_images, results)
					else
						original_image_metadata = original_image_metadata || {}
						image_function_result = handle_image_functions(image_or_images, results) || {}
						original_image_metadata.merge!(image_function_result)
					end
				end
			end

			@message_wrapper.touch
		rescue => ex
			@message_wrapper.touch
			BlitlineLogger.log(ex)
			# Different Version error handling
			if @data["v"] && @data["v"].to_f > 1.17
				error_hash = {}
				error_hash["error"] = "Image processing failed. " + ex.message
				if @data['functions']
					failed_image_identifiers = []
					get_image_identifiers(@data['functions'], failed_image_identifiers)
					error_hash["failed_image_identifiers"] = failed_image_identifiers
				end
				results << error_hash
			else
				results << {'error' => "Image processing failed. " + ex.message}
				if @data['functions']
					failed_image_identifiers = []
					get_image_identifiers(@data['functions'], failed_image_identifiers)
					results << {'failed_image_identifiers' => failed_image_identifiers}
				end
			end
			# Force retry if explicitly asked for
			if @data["wait_retry_delay"]
				begin
					releases_already = @message_wrapper.release_count
					BlitlineLogger.log("releases_already=#{releases_already.to_s}")
					if (releases_already < 5)
						if (@data["wait_retry_delay"].to_i < 0 || @data["wait_retry_delay"].to_i > 100)
							@data["wait_retry_delay"] = 5
						end
						@message_wrapper.release(@data["wait_retry_delay"].to_i)
						BlitlineLogger.log("wait_retry_delay=" + @data["wait_retry_delay"].to_s + "s .... Retrying later")
						return
					else
						BlitlineLogger.log("The ONE TRUE death #{task_id}")
					end
				rescue => reex
					BlitlineLogger.log(reex)
				end
			end
		end

		if @data['drop_current_job'].to_s == "true"
			BlitlineLogger.log("Dropping job")
			return
		end

		pb_delt = 0.0
		# BlitlineLogger.log("Run Results:"+::Yajl::Encoder.encode(results))
		unless @message_wrapper.released? # If we released it back into the wild, we don't postback
			if type=="postback" && src_type != Blitline::Constants::SRC_TYPE_BURST_PDF
				begin
					@message_wrapper.touch
					pb_delt = get_delta do
						handle_postback(@data, original_image_metadata, results, @task_id)
					end

				rescue Timeout::Error => pex
					@data['postback_error'] = "Timeout on postback #{pex.message} : " + @data['postback_url'].inspect
					BlitlineLogger.log("Failed Postback")
					BlitlineLogger.log(pex)
				rescue => ex
					@data['postback_error'] = "Failed postback #{ex.message} : " + @data['postback_url'].inspect
					BlitlineLogger.log("Failed Postback")
					BlitlineLogger.log(ex)
				end
			end
		else
			BlitlineLogger.log("Released due to s3 bungling")
		end


		begin
			# Track deltas
			q_delt=0.0
			if @data['q_ts']
				begin
					q_delt = @start_time.to_f - @data['q_ts'].to_f
				rescue => tiex
					BlitlineLogger.log("q_delt Calc Failure")
					BlitlineLogger.log(tiex)
				end
			end
			q_delt = q_delt || 0
			d_delt = d_delt || 0
			f_delt = f_delt || 0
			pb_delt = pb_delt || 0

			@data["q_delt"] = sprintf("%05.6f", q_delt) # Download delta
			@data["d_delt"] = sprintf("%05.3f", d_delt) # Download delta
			@data["f_delt"] = sprintf("%05.3f", f_delt) # Function delta
			@data["pb_delt"] = sprintf("%05.3f", pb_delt) # Postback delta
			@data["h"] = Blitline::Constants::HOSTNAME

			@job_info_persistence.persist_job_end_info(task_id, @data, @start_time, Time.now, results, original_image_metadata) unless @data['is_preprocessing']
			
			BlitlineLogger.log("Safe here")
			unless @message_wrapper.released? # If we released it back into the wild, we don't postback
				
				force_longpoll_cache = (@data["force_longpoll_cache"] && @data["force_longpoll_cache"].to_s.downcase=="true")
				
				# --------------------------------------------------------
				# Handle atomic jobs
				# --------------------------------------------------------
				if @data["src_data"] && @data["src_data"]["parent_job_id"]
					parent_job_id = @data["src_data"]["parent_job_id"]
					atomic_count = @job_info_persistence.decrement_atomic_count(parent_job_id)
					if atomic_count==0
						atomic_data = @job_info_persistence.get_atomic_data(parent_job_id)
						postback_url = atomic_data["postback_url"]
						results_data = { "image_results" => atomic_data["results_data"]}
						if postback_url
							@data["postback_url"] = postback_url
							BlitlineLogger.log("Job Group Result Postback")
							puts "Job Group Result Postback", results_data
							handle_postback(@data, {}, results_data, parent_job_id)
						end

						if (type!="postback" || force_longpoll_cache) && !is_pre_process
							BlitlineLogger.log("Job Group Result Cache Push")
							handle_push_to_cache(@data, {}, results_data, parent_job_id)
						else
							BlitlineLogger.log("Not sending to cache")
						end									
					end
				else # All other jobs
					if (type!="postback" || force_longpoll_cache) && !is_pre_process
						handle_push_to_cache(@data, original_image_metadata, results, @task_id)
					else
						BlitlineLogger.log("Not sending to cache")
					end									
				end
			end
			BlitlineLogger.log("Exiting")
		rescue => exf
			BlitlineLogger.log("Exiting with failure")
			BlitlineLogger.log(exf)
		end

	end

	private

	def handle_push_to_cache(data, original_image_metadata, results, task_id)
		begin
			if data['wait_for_s3']
				s3_urls = []
				results.each do |image_result|
					s3_urls << image_result["s3_url"]
				end
				wait_for_s3(s3_urls)
			end
			send_notify = true

			# Handle postback/notify for error only
			if data['notify_error_only']
				send_notify = false
				has_error = false
				results.each do |result|
					if result["error"]
						has_error = true
					end
				end
				send_notify = has_error
			end
			result_key_name = :results
			if data["src_type"] == Blitline::Constants::SRC_TYPE_ZIP
				result_key_name = :results
			else
				result_key_name = :images
			end

			if send_notify
				cache_url = "http://cache.blitline.com/pub?id=#{task_id}"
				BlitlineLogger.log("Sending to #{cache_url}")
				if data["v"] && data["v"].to_f > 1.18
					if data["v"].to_f > 1.19
						errors, failed_image_identifiers = get_errors_and_failed_image_identifiers_from_results(results)
						images_data = { :original_meta => original_image_metadata, result_key_name => results, :job_id => task_id}	
						images_data[result_key_name.to_sym][:errors] = errors if errors && errors.length > 0 && images_data[result_key_name.to_sym].is_a?(Hash)
						images_data[result_key_name.to_sym][:failed_image_identifiers] = failed_image_identifiers if failed_image_identifiers && failed_image_identifiers.length > 0 && images_data[result_key_name.to_sym].is_a?(Hash)
					else
						images_data = { :original_meta => original_image_metadata, result_key_name => results, :job_id => task_id}
					end
				else
					images_data = Oj.dump({:original_meta => original_image_metadata, result_key_name => results, :job_id => task_id}, { :mode  => :compat })
				end
				Blitline::HttpClient.post_as_json(cache_url, { :results => images_data}, {:username => Blitline::Constants::CACHE_USERNAME, :password => Blitline::Constants::CACHE_PASSWORD})
			end
		rescue => ex
			BlitlineLogger.log(ex)
		end
	end

	def get_errors_and_failed_image_identifiers_from_results(results)
		errors = []
		failed = []
		successfull_images = []


		results.each do |image_data|
			if image_data 
				if image_data["error"]
					error_text = image_data.delete("error")
					errors << error_text
					if image_data["failed_image_identifiers"]
						failed = failed + image_data.delete("failed_image_identifiers")
					end
				elsif image_data["image_identifier"]
					successfull_images = successfull_images + [image_data["image_identifier"]]
				end
			end
		end

		results.delete_if do |result|
			result.is_a?(Hash) && result.empty?
		end

		failed = failed - successfull_images
		return errors, failed.uniq
	end

	def handle_postback(data, original_image_metadata, results, task_id)
		if data['wait_for_s3']
			s3_urls = []
			results.each do |image_result|
				s3_urls << image_result["s3_url"]
			end
			wait_for_s3(s3_urls)
		end
		send_postback = true

		# Handle postback for error only
		if data['postback_error_only']
			send_postback = false
			has_error = false
			results.each do |result|
				if result["error"]
					has_error = true
				end
			end
			send_postback = has_error
		end

		if data["src_type"] == Blitline::Constants::SRC_TYPE_ZIP
			result_key_name = :results
		else
			result_key_name = :images
		end


		if send_postback
			data_to_encode = {:original_meta => original_image_metadata, result_key_name => results, :job_id => task_id}
			if has_error_in_images?(results)
				data_to_encode["error"] = "true"
			end
			images_data = Yajl::Encoder.encode(data_to_encode)
			BlitlineLogger.log("Posting to #{data['postback_url'].inspect } --> #{images_data}" )
			if data['postback_url'].is_a?(Hash)
				if data['postback_url']["save"]
					@uploader.upload_json_to_s3(task_id, { :results => {:original_meta => original_image_metadata, result_key_name => results, :job_id => task_id}}, data['postback_url']["save"])
				end					
			else
				if data['content_type_json'] || (data["v"] && data["v"].to_f > 1.17)
					options = {}
					if data['postback_headers'] && data['postback_headers'].is_a?(Hash)
						options[:headers] = data['postback_headers']
					end
					returned_json = { :results => {:original_meta => original_image_metadata, :images => results, :job_id => task_id}}
					if data["v"].to_f > 1.19
						errors, failed_image_identifiers = get_errors_and_failed_image_identifiers_from_results(results)
						returned_json[:results][:errors] = errors if errors && errors.length > 0
						returned_json[:results][:failed_image_identifiers] = failed_image_identifiers if failed_image_identifiers && failed_image_identifiers.length > 0
					end
					Blitline::HttpClient.post_as_json(data['postback_url'], returned_json, options)
				else
					Blitline::HttpClient.post(data['postback_url'], { :results => images_data})
				end
			end
		end
	end


	def has_error_in_images?(image_results)
		begin
			if image_results.is_a?(Array)
				image_results.each do |image_result|
					return true if image_result["error"]
				end
			end
		rescue => ex
			BlitlineLogger.log(ex)
		end
		return false
	end

	def wait_for_s3(s3_urls)
		1.upto(5) do
			all_exist = true
			s3_urls.each do |url|
				unless Blitline::HttpClient.exists?(url)
					all_exist = false
					BlitlineLogger.log "...waiting"
					break;
				end
			end
			return if all_exist
			sleep 2
		end
	end

	def handle_multipage_source(src_type, image_or_images, results)
		pages_array = nil
		# If individual pages are defined, return only those pages
		if src_type.is_a?(Hash) && src_type['pages']
			pages_array = arrayify(src_type['pages'])
		end

		image_or_images.each_with_index do |single_image, index|
			if pages_array.nil?

				handle_image_functions(single_image, results, index) # image_or_images is single_image
			else
				if pages_array.include?(index)
					handle_image_functions(single_image, results, index)
				end
			end
		end

		return nil
	end

	def handle_image_functions(image, results, index = nil)
		meta_data_options = {}
		if @data['hash']
			meta_data_options[:hash] = @data['hash']
			meta_data_options[:url] = Blitline::Utils.attempt_to_gracefully_handle_url(@data['src'])
		end

		if @data['extended_metadata']
			meta_data_options[:extended_metadata] = true
		end

		if @data['include_iptc']
			meta_data_options[:include_iptc] = true
		end

		original_image_metadata = meta_data_from_image(image, meta_data_options)

		image.auto_orient! unless @data['suppress_auto_orient'].to_s == "true"
		BlitlineLogger.log("Image loaded, Executing Functions")
		raise "Image size too large. 500MB max on image" if image.filesize > IMAGE_SIZE_MAX
		functions = @data['functions']
		execute_functions(functions, image, results, index)
		image.destroy! unless @data['cache_images'].to_s=="true"
		return original_image_metadata
	end


	def validate_initial_data
		raise "Invalid AWS access codes" if @config['aws_access_key'].nil? || @config['aws_access_secret'].nil?
		raise "No source for processing" unless @data['src']
		return if @data['src_type'] == Blitline::Constants::SRC_TYPE_GIF
		return if @data['src_type'] == Blitline::Constants::SRC_TYPE_ZIP
		return if @data['src_type'] == Blitline::Constants::SRC_TYPE_PREPROCESS_ONLY
		raise "Functions are required, or we're aren't doing anything (null op)" unless @data['functions'] 
	end

	def execute_functions(functions, image, results, index)
		functions.each do |function|
			image_processor = Blitline::ImageProcessor.new(image, @image_cache, @uploader)
			if function['name'] && function['name'].to_s[0,7]=="imagga_"
				send_to_external("imagga", image, function)
				return
			end
			new_image = image_processor.send(function['name'], function['params'] || {})
			if function['save']
				if function['save']['s3_destination']
					results << save(new_image, function['save'], index, "s3")
				end
				if function['save']['azure_destination']
					results << save(new_image, function['save'], index, "azure")
				end
                                if function['save']['ftp_destination']
                                        results << save(new_image, function['save'], index, "ftp")
                                end
			end
			execute_functions(function['functions'], new_image, results, index) if function['functions']
		end
	end

	def send_to_external(name, image_object, original_function)
		imagga = Blitline::ImaggaWrapper.new
		imagga.map_function_data_to_imagga(image_object, original_function, @uploader, @config, @data, @task_id)
	end


	def save(image, data, index, destination)
		return_data = {}
		raise "No image for outputting" unless image
		return return_data if data['skip'] && data['skip'].to_s.downcase == "true"

		blitline_id = data['blitline_id']

		file_path = nil
		suffix = index ? "_" + index.to_s : nil
		begin
			if data['s3_destination'] || data['azure_destination'] || data['ftp_destination']
				# Prepare save info
				if destination == "s3"
					bucket = data['s3_destination']['bucket']
					key = data['s3_destination']['key']
					type = data['s3_destination']['force_type']
					headers = data['s3_destination']['headers']
				elsif destination == "azure" # Azure Destination
					type = data['azure_destination']['force_type']
					key = ""
					bucket = ""
					headers = data['azure_destination']['headers']
				elsif destination == "ftp"
                                        type = data['ftp_destination']['force_type']
					key = data['ftp_destination']['filename']
                                        bucket = data['ftp_destination']['directory']
                                        headers = {}
                                end

				extension = (File.extname(key) == "") ? ".jpg" : File.extname(key)
				if type # If force type defined, it overrides file type for key
					extension = (type[0]=="." ? type : "." + type)
				end

				if suffix
					path, filename = File.split(key)
					basename = File.basename(filename, extension)
					basename = basename + suffix + extension

					if filename == key
						key = basename
					else
						key = [path, basename].join("/")
					end
				end

				return_data['image_identifier'] = data['image_identifier'] + suffix.to_s
				save_metadata = (data['save_metadata'].to_s == "true")
				save_profiles = (data['save_profiles'].to_s == "true")

				if data["v"] && data["v"].to_f > 1.19
					# Force save profiles unless explicitly told not to
					save_profiles = true unless data['save_profiles'].to_s == "false"
				end

				interlace = data['interlace']
				png_quantize = data['png_quantize']
				quality = data['quality']
				encoding_options = data['encoding_options']

				image.interlace = ::Blitline::ImageProcessor.save_interlace_from_name(interlace) if interlace

				quality = 75 if quality.nil?
				# Save image
				file_path = save_image(image, blitline_id, extension, quality, save_metadata, save_profiles, png_quantize, encoding_options)
				# Upload image
				if destination == "s3"
					return_data['s3_url'] = custom_upload(file_path, bucket, key, headers)
					if data['s3_destination'] && data['s3_destination']["return_keys"].to_s.downcase == "true"
						return_data['s3_key'] = key
					end

					if return_data['s3_url'].is_a?(Hash) && return_data['s3_url'][:error]
						return_data['error'] = return_data['s3_url'][:error]
						if (return_data['error'].include?("InvalidArgument"))
							return_data['error'] = "S3 returned an 'InvalidArgument' exception. Often this is the result of an incorrect Cannonical ID entered on Blitline, or a custom header that is malformed'"
						end
						return_data['s3_url'].delete(:error)
					end
				elsif destination == "azure"  # Azure destination
					account_name = data['azure_destination']['account_name']
					shared_access_signature = data['azure_destination']['shared_access_signature']
					return_data['azure_url'] = custom_upload_to_azure(account_name, shared_access_signature, file_path, headers)
					if return_data['azure_url'].is_a?(Hash) && return_data['azure_url'][:error]
						return_data['error'] = return_data['azure_url'][:error]
						return_data['azure_url'].delete(:error)
					end
                                elsif destination == "ftp"
                                        server = data['ftp_destination']['server']
                                        user = data['ftp_destination']['user']
 					password = data['ftp_destination']['password']
                                        data['ftp_destination']['password'] = "**REDACTED**"
                                        data['ftp_destination']['user'] = "**REDACTED**"
                                        return_data['ftp_path'] = custom_upload_to_ftp(file_path, server, bucket, key, user, password)
                                        if return_data['ftp_path'].is_a?(Hash) && return_data['ftp_path'][:error]
                                                return_data['error'] = return_data['ftp_path'][:error]
                                                return_data['ftp_path'].delete(:error)
                                        end
				end

				return_data['meta'] = { 'width' => image.columns, 'height' => image.rows}
				if @data['extended_metadata']
					return_data['meta']['filesize'] = File.size?(file_path)
					return_data['meta']['density'] = image.density
					return_data['meta']['depth'] = image.depth
					return_data['meta']['quality'] = image.quality
				end
			else
				raise "Everything should use a destination now"
			end
			begin
				if @data["cache_images"]
					BlitlineLogger.log("Caching #{data['image_identifier']}")
					@image_cache[data['image_identifier']] = image
				end
			rescue => ciex
				BlitlineLogger.log("Failed to cache image")
				BlitlineLogger.log(ciex)
			end
		ensure
			FileUtils.rm file_path if !file_path.nil? && File.exists?(file_path)
		end
		return return_data
	end

    def custom_upload_to_ftp(file_path, server, bucket, key, user, password)
            begin
                    destination_url = @uploader.upload_to_ftp(file_path, server, bucket, key, user, password)
                    return destination_url
            rescue => ex
                    BlitlineLogger.log(ex)
            end
    end

	def custom_upload_to_azure(account_name, shared_access_signature, file_path, headers)
		begin
			destination_url = @uploader.upload_to_azure(account_name, shared_access_signature, file_path, headers)
			return destination_url
		rescue => ex
			BlitlineLogger.log(ex)
		end
	end

	def custom_upload(file_path, bucket, key, headers)
		begin
			destination_url = @uploader.upload_to_s3(file_path, bucket, key, headers, @config['canonical_id'], @config['public_token'])
			if (destination_url.is_a?(Hash) && destination_url[:error] && (destination_url[:error].include?("temporarily unavailable") || destination_url[:error].include?("pipe")))
				@message_wrapper.release
			end
		rescue => ex
			BlitlineLogger.log(ex)
		end
		return destination_url
	end

	def meta_data_from_image(image, options)
		meta_data = {}
		return meta_data unless image

		begin
			meta_data['width'] = image.columns
			meta_data['height'] = image.rows

			if options[:hash]
				meta_data['hash'] = ::Blitline::ExternalTools.get_hash(options[:hash], options[:url])
			end

			if options[:extended_metadata].to_s == "true"
				meta_data['all_exif'] = image.get_exif_by_entry
				meta_data['filesize'] = image.filesize
			end

			if options[:include_iptc].to_s == "true"
				meta_data['iptc'] = {}
				image.each_iptc_dataset do |dataset, data_field|
					meta_data['iptc'][dataset] = data_field
				end
				puts meta_data
			end

			date_created = nil
			date_result = image.get_exif_by_entry("DateTimeOriginal")
			if date_result && date_result[0] && date_result[0].length > 1 && date_result[0][1]
				date_created = date_result[0][1]
			else
				date_result = image.get_exif_by_entry("DateTime")
				if date_result && date_result[0] && date_result[0].length > 1 && date_result[0][1]
					date_created = date_result[0][1]
				end
			end

			if date_created
				meta_data['date_created'] = date_created
				if @data && @data["v"].to_f > 1.19
					iso_date = Chronic.parse(date_created)
					if iso_date
						meta_data['iso_date_created'] = iso_date.iso8601(4) 
					end
				end
			end

			lat_result  = image.get_exif_by_entry("GPSLatitude")
			lat         = lat_result[0][1] if lat_result && lat_result[0] && lat_result[0][1]
			lng_result  = image.get_exif_by_entry("GPSLongitude")
			lng         = lng_result[0][1] if lng_result && lng_result[0] && lng_result[0][1]
			lat_ref_result = image.get_exif_by_entry("GPSLatitudeRef")
			lat_ref     = lat_ref_result[0][1] if lat_ref_result[0] && lat_ref_result[0][1]
			lng_ref_result = image.get_exif_by_entry("GPSLongitudeRef")
			lng_ref     = lng_ref_result[0][1] if lng_ref_result[0] && lng_ref_result[0][1]

			if lat && lng
				meta_data['lat'] = Blitline::Utils.sexagesimal_to_decimal(lat, lat_ref)
				meta_data['lng'] = Blitline::Utils.sexagesimal_to_decimal(lng, lng_ref)
			end

		rescue => ex
			BlitlineLogger.log(ex)
		end

		return meta_data
	end

	def save_image(image, secret, extension, quality, save_metadata, save_profiles, png_quantize, encoding_options)
		quality = 90 if quality.nil?
		download_file_directory = DOWNLOAD_FILE_DIR
		save_file_path = File.join(download_file_directory, secret + extension)
		color_profile = nil

		if save_profiles
			begin
				# Exclude iptc profile, and use only color profiles
				color_profile = image.color_profile
			rescue => exep
				BlitlineLogger.log(exep)
			end
		end

		unless save_metadata
			image.strip!
		end

		image.color_profile = color_profile if color_profile

		if encoding_options && extension.downcase == ".webp"
			temp_filepath = save_file_path + ".png"
			image.write(temp_filepath)
			encoding_options.reject! {|k,v| v.to_s.length > 8 }

			encoding_params = []

			encoding_options.each do |k,v|
				encoding_params << "-define webp:#{k}=#{v}"
			end
			convert_params = encoding_params.join(" ")
			::Blitline::ExternalTools.unsafe_convert_command(convert_params, temp_filepath, save_file_path)
		else
			image.write(save_file_path) {
				self.quality = quality.to_i
				self.interlace = image.interlace
			}
		end

		if png_quantize && extension.downcase == ".png"
			val = png_quantize.to_s.downcase == "true" ? 5 : png_quantize.to_i

			val = 5 if val == 0 # Force val to 5 if 0
			BlitlineLogger.log("PNG Quant=#{val.inspect}")
			::Blitline::ExternalTools.convert_to_png8(save_file_path, val)
			# Reload Image
			#			image = Magick::Image.read(save_file_path).first
		end

		return save_file_path
	end

	def arrayify(string_or_array)
		return string_or_array.is_a?(String) ? ::Yajl::Parser.parse(string_or_array) : string_or_array
	end

	def get_image_identifiers(functions, results)
		return if functions.nil?

		functions.each do |function|
			if function['save']
				results << function['save']['image_identifier']
			end
			get_image_identifiers(function['functions'], results) if function['functions']
		end
	end

	def get_delta
		start_time = Time.now.to_f
		yield
		end_time = Time.now.to_f
		return end_time - start_time
	end

end
