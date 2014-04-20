require 'blitline/job/utils'
require 'blitline/job/uploader'
require 'blitline/job/constants'
require 'blitline/job/http_client'
require 'oj'
require 'aes'
require 'timeout'

module Blitline
  class ImaggaWrapper

    # Live one!
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
			sleep 1
		end
	end

	def scale_image_to_1024(image)
		scale = 1.0
		if image && image.columns > 1024
			BlitlineLogger.log("Imagga +1024")
			scale = image.columns.to_f / 1024.0
			image.resize_to_fit!(1024)
		end
		return scale
	end

	def map_function_data_to_imagga(image, original_function, uploader, config, job_data, task_id)
		bucket = config["bucket"]
		key = "tmp_folder/" + Blitline::Utils.suid + ".png"
		url = uploader.upload_to_s3_from_image(image, bucket, key)
		
		scaled_key = "tmp_folder/scaled_" + Blitline::Utils.suid + ".jpg"
		scale = scale_image_to_1024(image)
		scaled_url = uploader.upload_to_s3_from_image(image, bucket, scaled_key)

		wait_for_s3([url,scaled_url])

		raise "Must have target resolution" unless original_function["params"]["resolution"]

		resolution = original_function["params"].delete("resolution")
		if resolution.is_a?(Hash)
			resolution = "#{resolution["width"]}x#{resolution["height"]}"
		end
		no_scaling = original_function["params"].delete("no_scaling") || "false"

		original_function["name"] = "crop_from_source"
		original_function["params"] = { "url" => url, "scale" => scale}

		original_data = {
			"job_data" => job_data,
			"url" => url ,# Acts as ID
			"scale" => scale
		}
		smart_crop(scaled_url, original_data, job_data["user_id"], resolution, no_scaling, config, task_id)
		job_data["drop_current_job"] = true
	end

	def map_function_data_from_imagga(data_from_imagga)
		data = Oj.load(data_from_imagga)

		# Handle Imagga Data
		imagga_results = data["imagga_results"]
		imagga_results_version = data["imagga_results_version"]

		# Build Blitline Data


		raw_json_original_blitline_data = AES.decrypt(data["original_blitline_data"], Blitline::Constants::AES_KEY)
		original_blitline_data = Oj.load(raw_json_original_blitline_data)

		config = original_blitline_data["config_data"]
		task_id = original_blitline_data["task_id"]

		parsed_job_data = original_blitline_data["job_data"]
		url = parsed_job_data["url"]
		scale = parsed_job_data["scale"] || 1.0
		job_data = parsed_job_data["job_data"]

		imagga_amount = job_data["imagga_data"].to_i
		job_data["imagga_data"] = imagga_amount + 1
		# Put data back into Blitline job

		functions = job_data["functions"]
		set_function_data(scale, url, imagga_results, functions)
        job_params = {'application_id' => job_data['application_id'], 'config' => config, 'data' => job_data, 'task_id' => task_id}
        return job_params
	end

	def convert_to_bool_int(val)
		return (val.to_s=="true" || val.to_s=="1") ? 1 : 0
	end

	def smart_crop(url, original_data, blitline_user_id, resolution, no_scaling, config_data, task_id)
		original_blitline_data = { "config_data" => config_data, "job_data" => original_data, "task_id" => task_id}
		original_blitline_data = AES.encrypt(Oj.dump(original_blitline_data), Blitline::Constants::AES_KEY)

		json = {
			"method" => "imagga.process.crop",
			"v" => 1.0,
			"urls"=> "#{url}",
			"resolutions" => resolution,
			"no_scaling" => convert_to_bool_int(no_scaling),
			"api_key" => "acc_2a8ec114",
			"original_blitline_data" => original_blitline_data,
			"blitline_user_id" => blitline_user_id
		}

		imagga_queue = Blitline::BeanstalkMQ.new(Blitline::Constants::IMAGGA_POOL)
		BlitlineLogger.log("Sending to Imagga JSON ******************************************** #{json}")
		BlitlineLogger.log("Sending to Imagga ******************************************** #{original_data}")
		imagga_queue.put(Oj.dump(json), 32000, 800, Blitline::Constants::IMAGGA_NAME)
	end

	def set_function_data(scale, url, data, function_array)

		function_array.each do |function|
			if function["name"] == "crop_from_source" && function["params"] && function["params"]["url"] == url
				function["params"] = data["smart_croppings"][0]["croppings"][0]
				function["params"]["url"] = url
				function["params"]["scale"] = scale
				return true
			end
			if function["functions"]
				set_function_data(scale, url, data, function["functions"])
			end
		end
	end


  end

end