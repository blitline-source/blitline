require 'blitline/job/constants'
require 'blitline/job/blitline_logger'
require 'blitline/job/external_tools' # Must be before image_processor
require 'blitline/job/image_processor'
require 'blitline/job/utils'
require 'blitline/job/uploader'
require 'oj'

module Blitline

	class JobGroupContainer
		TEMP_DIR = "/tmp"

		def initialize(application_id, config, data, uploader, job_info_persistence, group_completion_job_id)
			@application_id = application_id
			@config = config
			@data = data
			@job_id = group_completion_job_id
			@uploader = uploader
			@job_info_persistence = job_info_persistence
			@group_completion_job_id = group_completion_job_id
		end

		def run_job_group(type)
			if type==Blitline::Constants::SRC_TYPE_BURST_PDF
				burst_pdf
			else
				raise "Don't recognize job group container"
			end
		end

	private


		def countify_s3_destination(s3_destination, count)
			key = s3_destination["key"]
			bucket = s3_destination["bucket"]
			if bucket.is_a?(Hash)
				location = bucket['location']
				bucket = bucket['name']
			end
			ex = File.extname(key)
			new_key  = ex.length > 0 ? key[0...-ex.length] : key
			ex = ".jpg" if ex.nil? || ex ==""

			if location
				server = "s3-#{location}.amazonaws.com"
			    # Non US Bucket
				destination = "http://" + server + "/" + bucket + "/" +  new_key + "__" + count.to_s + ex
			else
			    # Standard US Bucket
				destination = "http://s3.amazonaws.com/"+ bucket + "/" +  new_key + "__" + count.to_s + ex
			end
		
			return destination
		end

		def read_destinations(functions, count, pre_process_s3_destination = nil)
			results = []
			location = nil
			functions.each do |function|
				if function["save"]
					if function["save"]["s3_destination"]
						0.upto(count - 1) do |i|
							image_identifier =  function["save"]["image_identifier"] + "__" + i.to_s
							destination = countify_s3_destination(function["save"]["s3_destination"], i)
							pre_process_destination = pre_process_s3_destination ? countify_s3_destination(pre_process_s3_destination, i) : nil
							result_item = { "url" => destination, "image_identifier" => image_identifier}
							if pre_process_destination
								result_item["move_original"] = pre_process_destination
							end
							results << result_item
						end
					end
				end

				if function["functions"]
					results = results + read_destinations(function["functions"], count)
				end
			end
			return results
		end

		def parse_pre_process_and_update_target(pre_process_data, index)
			if pre_process_data
				if pre_process_data["move_original"]
					# Move original
					move_info = pre_process_data["move_original"]
					s3_destination = move_info["s3_destination"]
					key = s3_destination["key"]
					bucket = s3_destination["bucket"]
					headers = s3_destination["headers"]
					
					ex = File.extname(key)
					new_key  = ex.length > 0 ? key[0...-ex.length] : key
					ex = ".jpg" if ex.nil? || ex ==""
					s3_destination["key"] = new_key + "__" + index.to_s + ex
				else
					BlitlineLogger.log("Only move_original Supported for Group Jobs! pre_process_data=#{pre_process_data}")
				end
			end
		end

		def parse_functions_and_update_target(functions, index)
			clone_functions = functions

			clone_functions.each do |function|
				if function["save"]
					save = function["save"]
					if save["image_identifier"]
						save["image_identifier"] = save["image_identifier"] + "__" + index.to_s
					end

					if save["s3_destination"]
						key = save["s3_destination"]["key"]
						ex = File.extname(key)
						new_key  = ex.length > 0 ? key[0...-ex.length] : key
						ex = ".jpg" if ex.nil? || ex ==""

						save["s3_destination"]["key"] = new_key + "__" + index.to_s + ex
					end

				end

				if function["functions"]
					parse_functions_and_update_target(function["functions"], index)
				end
			end

			return clone_functions
		end

		def upload_file_to_s3(src, target)
			bucket = @config["bucket"]
			key = target
			headers = {}
			destination_url = @uploader.upload_to_s3(src, bucket, key, headers, @config['canonical_id'], @config['public_token'])
			return destination_url
		end

		def re_jobify(src_url, application_id, index, function_data, pre_process)
			src_data = @data["src_data"] || {}
			src_data["parent_job_id"] = @job_id
			cloned_function_data = parse_functions_and_update_target(function_data, index)
			parse_pre_process_and_update_target(pre_process, index)

			json = {"json" => {
			    "application_id" => @application_id,
			    "src" => src_url,
			    "src_data" => src_data,
				"pre_process" => pre_process,
				"wait_retry_delay" => 10,
			    "functions" => cloned_function_data
			}}
			puts "re_jobify #{json.inspect}"
			result = Blitline::HttpClient.post_as_json("http://#{Blitline::Constants::API_HOSTNAME}/job", json)
			hash_result = Oj.load(result.body)
			job_id = hash_result["results"]["job_id"]
			return job_id
		end

		def download_file(data, uploader)
			src = data["src"]
			filepath = nil
			if src.is_a?(Hash) # If src is a hash, handle separately
				src_bucket = src['bucket']
				src_key = src['key']
				filepath = uploader.download_from_s3(src_key, src_bucket)
			else
				filepath = Blitline::HttpClient.download_file(src)
			end
			return filepath
		end


		def burst_pdf
			input_path = download_file(@data, @uploader)

			# Create temp folder
			output_folder = "/tmp/"+Blitline::Utils.suid
			FileUtils.mkdir(output_folder)
			sleep(1)
			job_ids =[]
			begin
				# Run Burst
				Blitline::ExternalTools.burst_pdf(input_path, output_folder)
				pages = []
				Dir.glob(output_folder + "/*.pdf").each do |pdf_page|
					pages << pdf_page
				end
				pages.sort!
				if pages.length == 0 
					raise "Could not successfully burst pdf. Error with PDF document."
				end
				if pages.length > 1000
					raise "PDF MUST be less than 1000 pages."
				end
				pre_process_data = nil
				if (@data["pre_process"] && @data["pre_process"]["move_original"] && @data["pre_process"]["move_original"]["s3_destination"])
					pre_process_data = @data["pre_process"]["move_original"]["s3_destination"]
				end

				returned_results = read_destinations(@data["functions"], pages.length, pre_process_data)
				data = {
					"postback_url" => @data["postback_url"],
					"results_data" => returned_results
				}
				BlitlineLogger.log("Atomic Data Save @job_id=#{@job_id} #{data}")

				@job_info_persistence.set_atomic_count(@job_id, pages.length, data)
				pages.each_with_index do |pdf_page, index|
					destination_url = upload_file_to_s3(pdf_page, Blitline::Utils.suid + ".pdf")
					raise "Functions are necessary" unless @data["functions"]
					functions = Marshal.load(Marshal.dump(@data["functions"]))
					pre_process = Marshal.load(Marshal.dump(@data["pre_process"]))
					job_id = re_jobify(destination_url, @application_id, index, functions, pre_process)
					job_ids << job_id
				end
			rescue => ex
				BlitlineLogger.log(ex)
				raise
			ensure
				FileUtils.rm input_path if !input_path.nil? && File.exists?(input_path)
				FileUtils.rm_rf(output_folder)
			end
		end
	end
end
