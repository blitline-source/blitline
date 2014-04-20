module Blitline
	class AltJob
		DOWNLOAD_FILE_DIR = "/tmp"

		def handle_gif_types(data, uploader, results, config, image_cache)
			begin
				filepath = download_file(data, uploader)
				name = Blitline::Utils.suid + ".gif"
				process_params = data["src_data"]["params"]
				save_params = data["src_data"]["save"]
				output_path = File.join("/tmp", name)
				name = data["src_data"]["name"]
				if (name == "resize_gif")
					resize_gif(:resize, filepath, output_path, process_params)
				elsif (name == "resize_gif_to_fit")
					resize_gif(:resize_to_fit, filepath, output_path, process_params)
				elsif (name == "gif_overlay")
					gif_overlay(filepath, output_path, process_params, uploader, image_cache)
				end
				upload_results = upload(output_path, save_params, config, uploader)
				results << upload_results
			ensure
				FileUtils.rm filepath if !filepath.nil? && File.exists?(filepath)
				FileUtils.rm output_path if !output_path.nil? && File.exists?(output_path)
			end
		end

private
		def resize_gif(type, filepath, output_path, process_params)
			Blitline::ImageProcessor.resize_gif(type, filepath, output_path, process_params)
		end

		def gif_overlay(filepath, output_path, process_params, uploader, image_cache)
			# Get original
			begin

				overlay_src = process_params["overlay_src"]

				image_loader = Blitline::ImageLoader.new(uploader, nil, image_cache, nil, nil)
				image = image_loader.load_original_image(overlay_src, nil, Blitline::Constants::SRC_TYPE_IMAGE)
				file_extension = Blitline::HttpClient.derive_file_extension(overlay_src)
				file_extension = ".png" if file_extension.blank?

				download_file_directory = DOWNLOAD_FILE_DIR
				tmp_file = File.join(download_file_directory,  Blitline::Utils.suid + file_extension)

				image.write(tmp_file)
				composite_params = {}
				::Blitline::ExternalTools.run_gif_composite(composite_params, filepath, tmp_file, output_path)
			ensure
				FileUtils.rm tmp_file if !tmp_file.nil? && File.exists?(tmp_file)
			end
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

		def upload(src_file, data, config, uploader)
			return_data = {}
			blitline_id = data['blitline_id']

			file_path = nil
			begin
				if data['s3_destination'] || data['azure_destination']
					# Prepare save info
					if data['s3_destination']
						bucket = data['s3_destination']['bucket']
						key = data['s3_destination']['key']
						type = data['s3_destination']['force_type']
						headers = data['s3_destination']['headers']
					elsif data['azure_destination'] # Azure Destination
						type = data['azure_destination']['force_type']
						key = ""
						bucket = ""
						headers = data['azure_destination']['headers']
					end

					extension = (File.extname(key) == "") ? ".gif" : File.extname(key)
					if type # If force type defined, it overrides file type for key
						extension = (type[0]=="." ? type : "." + type)
					end

					return_data['image_identifier'] = data['image_identifier']

					# Upload image
					if data['s3_destination']
						return_data['s3_url'] = s3_upload(uploader, src_file, bucket, key, headers, config)						
						if return_data['s3_url'].is_a?(Hash) && return_data['s3_url'][:error]
							return_data['error'] = return_data['s3_url'][:error]
						end
						if data['s3_destination']["return_keys"].to_s.downcase == "true"
							return_data['s3_key'] = key
						end
					elsif data['azure_destination']  # Azure destination
						account_name = data['azure_destination']['account_name']
						shared_access_signature = data['azure_destination']['shared_access_signature']
						return_data['azure_url'] = custom_upload_to_azure(uploader, account_name, shared_access_signature, file_path, headers)
						if return_data['azure_url'].is_a?(Hash) && return_data['azure_url'][:error]
							return_data['error'] = return_data['azure_url'][:error]
						end
					end

				else
					raise "Everything should use a destination now"
				end
			ensure
				FileUtils.rm file_path if !file_path.nil? && File.exists?(file_path)
			end
			return return_data
		end

		def s3_upload(uploader, file_path, bucket, key, headers, config)
			begin
				destination_url = uploader.upload_to_s3(file_path, bucket, key, headers, config['canonical_id'], config['public_token'])
			rescue => ex
				BlitlineLogger.log(ex)
			end
			return destination_url
		end

		def custom_upload_to_azure(uploader, account_name, shared_access_signature, file_path, headers)
			begin
				destination_url = uploader.upload_to_azure(account_name, shared_access_signature, file_path, headers)
				return destination_url
			rescue => ex
				BlitlineLogger.log(ex)
			end
		end


	end
end